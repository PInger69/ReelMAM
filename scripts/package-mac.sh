#!/bin/bash
# Builds StradaXR Ingest and StradaXR A.I. MAM in Release, signs them, and makes installers:
# a disk image (drag to Applications) and an installer package (installs into /Applications).
#
# Unsigned (for testing; macOS warns on first open):
#   scripts/package-mac.sh
#
# Signed with Developer ID and notarized by Apple (opens on any Mac with no warning):
#   scripts/package-mac.sh --sign "Developer ID Application: Your Name (TEAMID)" \
#                          --installer-sign "Developer ID Installer: Your Name (TEAMID)" \
#                          --notary-profile stradaxr
#
# The notary profile is made once on the Mac with:
#   xcrun notarytool store-credentials stradaxr --apple-id you@example.com --team-id TEAMID
# (it asks for an app-specific password from appleid.apple.com), or give an App Store Connect
# API key with --notary-key AuthKey_XXXX.p8 --notary-key-id XXXX --notary-issuer <issuer id>.
#
# Other options: --app ingest|mam|all (default all), --version 0.2.0, --build 42, --out dist
set -euo pipefail

APPS="all"
SIGN=""
INSTALLER_SIGN=""
NOTARY_PROFILE=""
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
VERSION=""
BUILD=""
OUT="dist"
KEYCHAIN_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APPS="$2"; shift 2 ;;
    --sign) SIGN="$2"; shift 2 ;;
    --installer-sign) INSTALLER_SIGN="$2"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    --notary-key) NOTARY_KEY="$2"; shift 2 ;;
    --notary-key-id) NOTARY_KEY_ID="$2"; shift 2 ;;
    --notary-issuer) NOTARY_ISSUER="$2"; shift 2 ;;
    --keychain) KEYCHAIN_ARGS=(--keychain "$2"); shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $1. See --help." >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
ROOT="$PWD"
PROJECT="StradaXR A.I. MAM.xcodeproj"
DERIVED="$ROOT/build/package"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

[ -n "$VERSION" ] || VERSION="$(grep -m1 'CFBundleShortVersionString:' project.yml | sed 's/.*"\(.*\)".*/\1/')"
[ -n "$BUILD" ] || BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

notarizing=false
if [ -n "$NOTARY_PROFILE" ] || [ -n "$NOTARY_KEY" ]; then
  notarizing=true
  [ -n "$SIGN" ] || { echo "Notarizing needs --sign with a Developer ID Application identity." >&2; exit 2; }
fi

if command -v xcodegen >/dev/null; then
  xcodegen generate --quiet
elif [ ! -d "$PROJECT" ]; then
  echo "The Xcode project is missing and xcodegen is not installed: brew install xcodegen" >&2
  exit 1
fi

notarize() {
  local file="$1"
  echo "Sending $(basename "$file") to Apple for notarization (this usually takes a few minutes)…"
  local args=()
  if [ -n "$NOTARY_PROFILE" ]; then
    args=(--keychain-profile "$NOTARY_PROFILE")
  else
    args=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  fi
  local result
  result="$(xcrun notarytool submit "$file" "${args[@]}" --wait --output-format json)"
  local status id
  status="$(echo "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  id="$(echo "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
  if [ "$status" != "Accepted" ]; then
    echo "Apple did not accept $(basename "$file") (status: ${status:-unknown}). Apple's log:" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "${args[@]}" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$file"
}

package() {
  local scheme="$1" bundle_id="$2" file_stem="$3"
  echo "== $scheme $VERSION ($BUILD)"
  if ! xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Release -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build > "$DERIVED-$file_stem.log" 2>&1; then
    grep -E "error:|BUILD FAILED" "$DERIVED-$file_stem.log" | sort -u | head -50 >&2
    exit 1
  fi
  local built="$DERIVED/Build/Products/Release/$scheme.app"
  local stage="$DERIVED/stage-$file_stem"
  rm -rf "$stage"; mkdir -p "$stage"
  ditto "$built" "$stage/$scheme.app"
  local app="$stage/$scheme.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$app/Contents/Info.plist"

  if [ -n "$SIGN" ]; then
    # Inside out: anything nested first, then the app, with the hardened runtime Apple requires.
    find "$app/Contents" \( -name "*.dylib" -o -name "*.framework" -o -name "*.bundle" -o -name "*.xpc" \) -prune -print0 2>/dev/null |
      while IFS= read -r -d '' nested; do
        codesign --force --options runtime --timestamp --sign "$SIGN" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$nested"
      done
    codesign --force --options runtime --timestamp --sign "$SIGN" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$app"
  else
    # Ad-hoc: runs on Apple Silicon, but macOS asks before opening it the first time.
    codesign --force --deep --sign - "$app"
  fi
  codesign --verify --deep --strict "$app"

  # Disk image: the app beside a link to Applications, to drag across.
  local dmg="$OUT/$file_stem-$VERSION.dmg"
  rm -f "$dmg"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname "$scheme" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
  rm "$stage/Applications"
  [ -n "$SIGN" ] && codesign --force --timestamp --sign "$SIGN" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$dmg"

  # Installer package: installs the app into /Applications.
  local pkg="$OUT/$file_stem-$VERSION.pkg"
  rm -f "$pkg"
  local pkg_sign=()
  [ -n "$INSTALLER_SIGN" ] && pkg_sign=(--sign "$INSTALLER_SIGN" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --timestamp)
  productbuild --component "$app" /Applications --identifier "$bundle_id.pkg" --version "$VERSION" ${pkg_sign[@]+"${pkg_sign[@]}"} "$pkg"

  if $notarizing; then
    notarize "$dmg"
    if [ -n "$INSTALLER_SIGN" ]; then notarize "$pkg"; else echo "The .pkg is not notarized: it needs --installer-sign." >&2; fi
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
  fi
  echo "   $dmg"
  echo "   $pkg"
}

case "$APPS" in
  ingest) package "StradaXR Ingest" com.stradaxr.mam.ingest "StradaXR-Ingest" ;;
  mam) package "StradaXR A.I. MAM" com.stradaxr.mam "StradaXR-AI-MAM" ;;
  all)
    package "StradaXR Ingest" com.stradaxr.mam.ingest "StradaXR-Ingest"
    package "StradaXR A.I. MAM" com.stradaxr.mam "StradaXR-AI-MAM"
    ;;
  *) echo "--app takes ingest, mam or all." >&2; exit 2 ;;
esac

if [ -z "$SIGN" ]; then
  echo "Not signed with a Developer ID: macOS will ask before opening these the first time (Control-click › Open)."
elif ! $notarizing; then
  echo "Signed but not notarized: macOS will still warn on other Macs. Add --notary-profile to notarize."
fi
