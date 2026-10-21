#!/bin/bash
# Builds MoxieTimer.app into ./build.
#   --install    copy to /Applications and launch
#   --universal  build for Apple Silicon + Intel
#   --adhoc      ad-hoc sign even when a Developer ID certificate is available
#   --notarize   notarize with Apple and staple the ticket (needs a Developer ID signature)
# VERSION / BUILD_NUMBER env vars override the bundle version.
# SIGN_IDENTITY (certificate name or SHA-1) and optional SIGN_KEYCHAIN choose the signing certificate.
# Without SIGN_IDENTITY the first "Developer ID Application" certificate in the keychain is used,
# falling back to ad-hoc signing when there is none.
# Notarization credentials: NOTARY_PROFILE (a profile saved with `xcrun notarytool store-credentials`)
# or APPLE_ID + APPLE_APP_PASSWORD (app-specific password) + APPLE_TEAM_ID.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
ADHOC=0
NOTARIZE=0
ARCH_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    --adhoc) ADHOC=1 ;;
    --notarize) NOTARIZE=1 ;;
  esac
done

if [[ "$ADHOC" == 1 ]]; then
  SIGN_IDENTITY=""
elif [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
  # No Developer ID: a self-signed "Moxie Timer Dev" certificate (Keychain Access → Certificate Assistant →
  # Create a Certificate, type Code Signing) keeps the signature stable between builds, so the Keychain
  # access prompt for the API keys appears once instead of after every rebuild.
  if [[ -z "$SIGN_IDENTITY" ]] && security find-identity -v -p codesigning | grep -q '"Moxie Timer Dev"'; then
    SIGN_IDENTITY="Moxie Timer Dev"
  fi
fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/MoxieTimer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MoxieTimer" "$APP/Contents/MacOS/MoxieTimer"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$APP/Contents/Info.plist"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  # Notarization requires the hardened runtime and a secure timestamp; Apple's timestamp service only
  # matters for Developer ID certificates.
  TIMESTAMP=--timestamp=none
  [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] && TIMESTAMP=--timestamp
  codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" \
    ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"
  codesign --verify --strict --deep "$APP"
  echo "Signed with $SIGN_IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Ad-hoc signed"
fi

if [[ "$NOTARIZE" == 1 ]]; then
  if [[ "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "--notarize needs a Developer ID Application signature." >&2
    exit 1
  fi
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
  else
    echo "Set NOTARY_PROFILE, or APPLE_ID + APPLE_APP_PASSWORD + APPLE_TEAM_ID, to notarize." >&2
    exit 1
  fi
  SUBMISSION="build/MoxieTimer-notarize.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION"
  echo "Submitting to Apple's notary service (usually a few minutes)…"
  OUTPUT="$(xcrun notarytool submit "$SUBMISSION" "${NOTARY_AUTH[@]}" --wait 2>&1)" || true
  echo "$OUTPUT"
  rm -f "$SUBMISSION"
  if ! grep -q "status: Accepted" <<<"$OUTPUT"; then
    ID="$(sed -n 's/^ *id: //p' <<<"$OUTPUT" | head -1)"
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${NOTARY_AUTH[@]}" || true
    echo "Notarization failed." >&2
    exit 1
  fi
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
  echo "Notarized and stapled"
fi

echo "Built $APP"

if [[ "$INSTALL" == 1 ]]; then
  pkill -x MoxieTimer 2>/dev/null || true
  rm -rf /Applications/MoxieTimer.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/MoxieTimer.app"
  open /Applications/MoxieTimer.app
fi
