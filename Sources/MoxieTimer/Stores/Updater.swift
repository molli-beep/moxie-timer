import AppKit
import CryptoKit
import Security
import Observation

/// Self-updater backed by GitHub Releases. Checks `releases/latest`, and if the tag is newer than the
/// running version, downloads the `.zip` asset, verifies it against the `.zip.sha256` asset,
/// swaps the app bundle in place and relaunches.
@MainActor @Observable
final class Updater {
    /// This fork's releases. Updates from the upstream project would overwrite the Notion sync, so they
    /// are not offered; merge upstream changes into the fork and cut a release there instead.
    static let repository = "molli-beep/moxie-timer"
    private static let checkInterval: TimeInterval = 6 * 3600

    struct Release: Equatable {
        let version: String
        let notes: String
        let pageURL: URL
        let zipURL: URL
        let checksumURL: URL?
    }

    enum State: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var latest: Release?
    private(set) var lastChecked: Date?

    var automaticallyChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecks, forKey: "autoUpdateCheck")
            schedule()
        }
    }

    @ObservationIgnored private var timer: Timer?

    init() {
        automaticallyChecks = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true
        schedule()
        // Skip the launch check for `swift run` builds, which have no bundle version to compare.
        if automaticallyChecks, Bundle.main.bundleURL.pathExtension == "app" {
            Task { await check(userInitiated: false) }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var isBusy: Bool {
        state == .checking || state == .downloading || state == .installing
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MoxieTimer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError("No response from GitHub.") }
            if http.statusCode == 404 {
                // The fork has no releases yet: nothing to update to.
                lastChecked = .now
                latest = nil
                state = .upToDate
                return
            }
            guard http.statusCode == 200 else { throw UpdateError("GitHub returned HTTP \(http.statusCode).") }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(GitHubRelease.self, from: data)
            lastChecked = .now

            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard Self.isVersion(version, newerThan: currentVersion),
                  let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                latest = nil
                state = .upToDate
                return
            }
            latest = Release(
                version: version,
                notes: release.body ?? "",
                pageURL: release.htmlUrl,
                zipURL: zip.browserDownloadUrl,
                checksumURL: release.assets.first { $0.name == zip.name + ".sha256" }?.browserDownloadUrl
            )
            state = .idle
        } catch {
            // Background checks fail quietly (offline, rate-limited…); only report ones the user asked for.
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automaticallyChecks else { return }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check(userInitiated: false) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Installing

    func installUpdate() async {
        guard let release = latest, !isBusy else { return }
        let appURL = Bundle.main.bundleURL
        let fileManager = FileManager.default

        guard appURL.pathExtension == "app" else {
            state = .failed("Updates only work from MoxieTimer.app, not a development build.")
            return
        }
        guard !appURL.path.contains("/AppTranslocation/") else {
            state = .failed("Move MoxieTimer.app into Applications, reopen it, then update.")
            return
        }
        guard fileManager.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            state = .failed("No permission to replace the app in \(appURL.deletingLastPathComponent().path).")
            return
        }

        state = .downloading
        do {
            // A scratch folder on the same volume as the app, so the final swap is an atomic rename.
            let work = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
            defer { try? fileManager.removeItem(at: work) }

            let (downloaded, response) = try await URLSession.shared.download(from: release.zipURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed.") }
            let zip = work.appending(path: "update.zip")
            try fileManager.moveItem(at: downloaded, to: zip)

            if let checksumURL = release.checksumURL {
                let (checksumData, _) = try await URLSession.shared.data(from: checksumURL)
                let expected = String(decoding: checksumData, as: UTF8.self)
                    .split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
                let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                guard expected == actual else { throw UpdateError("The download didn't match its checksum.") }
            }

            state = .installing
            let extracted = work.appending(path: "extracted")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
            let newApp = extracted.appending(path: "MoxieTimer.app")
            guard let bundle = Bundle(url: newApp),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("The download doesn't contain Moxie Timer.")
            }
            // Once this app is signed with a real certificate, only accept updates signed by the same one
            // or by Moxie Timer's Developer ID team.
            if let current = Self.signingCertificate(of: Bundle.main.bundleURL) {
                guard Self.hasValidSignature(newApp),
                      Self.signingCertificate(of: newApp) == current || Self.isSignedByDeveloperTeam(newApp) else {
                    throw UpdateError("The update isn't signed with Moxie Timer's certificate, so it wasn't installed.")
                }
            }
            try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            _ = try fileManager.replaceItemAt(appURL, withItemAt: newApp)
            relaunch(appURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Waits for this process to exit, then reopens the (replaced) bundle.
    private func relaunch(_ appURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", appURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Updated — please reopen Moxie Timer.")
        }
    }

    // MARK: Helpers

    /// DER data of the leaf signing certificate; nil for ad-hoc or unsigned code.
    static func signingCertificate(of url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    /// The bundle's signature is intact and satisfies its own designated requirement.
    static func hasValidSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
    }

    /// Apple Developer team that signs and notarizes releases.
    static let developerTeamID = "787XM95RYN"

    /// Signed with a genuine Apple-issued Developer ID Application certificate from `developerTeamID`.
    static func isSignedByDeveloperTeam(_ url: URL) -> Bool {
        let rule = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(developerTeamID)\""
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateError("\(URL(fileURLWithPath: path).lastPathComponent) failed (\(process.terminationStatus)).")
            }
        }.value
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
    }

    let tagName: String
    let body: String?
    let htmlUrl: URL
    let assets: [Asset]
}
