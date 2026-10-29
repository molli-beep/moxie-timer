import Foundation

/// Thin client for the Notion API (https://developers.notion.com), API version 2025-09-03.
/// Pages are read and written as loosely typed JSON so the sync code can stay small.
struct NotionAPI: Sendable {
    let token: String

    private static let base = URL(string: "https://api.notion.com/v1")!
    private static let version = "2025-09-03"

    enum APIError: LocalizedError {
        case http(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(401, _):
                return "Notion rejected the integration token (check Settings → Notion)."
            case .http(404, let body):
                if body.contains("Could not find") {
                    return "Notion can't see one of the databases — open it in Notion, use ··· → Connections, and add the Moxie Timer integration."
                }
                return "Notion returned HTTP 404."
            case let .http(code, body):
                let message = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["message"] as? String
                return "Notion returned HTTP \(code)\(message.map { ": \($0)" } ?? ".")"
            case .invalidResponse:
                return "Unexpected response from Notion."
            }
        }
    }

    /// One row of a database, with the handful of property shapes the sync reads.
    struct Page {
        let id: String
        let properties: [String: Any]

        func text(_ property: String) -> String? {
            guard let prop = properties[property] as? [String: Any] else { return nil }
            let type = prop["type"] as? String ?? ""
            let parts = prop[type] as? [[String: Any]] ?? []
            let joined = parts.compactMap { $0["plain_text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }

        func status(_ property: String) -> String? {
            ((properties[property] as? [String: Any])?["status"] as? [String: Any])?["name"] as? String
        }

        func select(_ property: String) -> String? {
            ((properties[property] as? [String: Any])?["select"] as? [String: Any])?["name"] as? String
        }

        func relationIds(_ property: String) -> [String] {
            ((properties[property] as? [String: Any])?["relation"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        }

        /// A number, or the number a formula or rollup works out to.
        func number(_ property: String) -> Double? {
            guard let prop = properties[property] as? [String: Any] else { return nil }
            if let value = prop["number"] as? Double { return value }
            if let value = (prop["formula"] as? [String: Any])?["number"] as? Double { return value }
            if let value = (prop["rollup"] as? [String: Any])?["number"] as? Double { return value }
            return nil
        }

        func dateStart(_ property: String) -> String? {
            ((properties[property] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String
        }
    }

    // MARK: Reading

    /// Every page of a data source that matches `filter` (nil = all), following pagination.
    func queryAll(dataSource: String, filter: [String: Any]? = nil) async throws -> [Page] {
        var pages: [Page] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let filter { body["filter"] = filter }
            if let cursor { body["start_cursor"] = cursor }
            let json = try await send("data_sources/\(dataSource)/query", method: "POST", body: body)
            let results = json["results"] as? [[String: Any]] ?? []
            pages += results.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return Page(id: id, properties: item["properties"] as? [String: Any] ?? [:])
            }
            cursor = (json["has_more"] as? Bool ?? false) ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return pages
    }

    /// Reads the data source to confirm the token works and the integration can see it. Returns its title.
    func dataSourceTitle(_ dataSource: String) async throws -> String {
        let json = try await send("data_sources/\(dataSource)")
        let parts = json["title"] as? [[String: Any]] ?? []
        let title = parts.compactMap { $0["plain_text"] as? String }.joined()
        return title.isEmpty ? "Untitled" : title
    }

    // MARK: Writing

    /// Creates a page in the data source. Returns the new page id.
    @discardableResult
    func createPage(dataSource: String, properties: [String: Any]) async throws -> String {
        let body: [String: Any] = [
            "parent": ["type": "data_source_id", "data_source_id": dataSource],
            "properties": properties,
        ]
        let json = try await send("pages", method: "POST", body: body)
        guard let id = json["id"] as? String else { throw APIError.invalidResponse }
        return id
    }

    func updatePage(_ id: String, properties: [String: Any]) async throws {
        _ = try await send("pages/\(id)", method: "PATCH", body: ["properties": properties])
    }

    // MARK: Property builders

    static func title(_ text: String) -> [String: Any] {
        ["title": [["type": "text", "text": ["content": String(text.prefix(2000))]]]]
    }

    static func richText(_ text: String?) -> [String: Any] {
        guard let text, !text.isEmpty else { return ["rich_text": []] }
        return ["rich_text": [["type": "text", "text": ["content": String(text.prefix(2000))]]]]
    }

    static func status(_ name: String) -> [String: Any] { ["status": ["name": name]] }
    static func select(_ name: String) -> [String: Any] { ["select": ["name": name]] }
    static func number(_ value: Double) -> [String: Any] { ["number": value] }
    static func url(_ value: String?) -> [String: Any] { ["url": value as Any? ?? NSNull()] }

    /// A date-only value (`yyyy-MM-dd`) or, with `time`, a full timestamp.
    static func date(_ start: Date, end: Date? = nil, time: Bool) -> [String: Any] {
        var value: [String: Any] = ["start": time ? iso(start) : day(start)]
        if let end { value["end"] = time ? iso(end) : day(end) }
        return ["date": value]
    }

    static func date(day: String) -> [String: Any] { ["date": ["start": day]] }
    static let noDate: [String: Any] = ["date": NSNull()]

    static func relation(_ ids: [String]) -> [String: Any] {
        ["relation": ids.map { ["id": $0] }]
    }

    private static func day(_ date: Date) -> String {
        MoxieTask.dayFormatter.string(from: date)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: Transport

    private func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: Self.base.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Notion allows about three requests a second; wait and retry once when it says so.
        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            if http.statusCode == 429, attempt < 2 {
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
                try await Task.sleep(for: .seconds(min(wait, 10)))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw APIError.invalidResponse
            }
            return json
        }
        throw APIError.invalidResponse
    }
}
