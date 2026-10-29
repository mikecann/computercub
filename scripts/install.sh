#!/usr/bin/env bash
# Builds Mitts.app, signs it, installs it to ~/Applications and links `mitts` onto PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${MITTS_APP_PATH:-$HOME/Applications/Mitts.app}"
CLI="${MITTS_CLI_PATH:-$HOME/.local/bin/mitts}"
BUNDLE_ID='app.mikecann.mitts'
cd "$ROOT"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/mitts"
STAGE_ROOT="$(mktemp -d "$ROOT/.build/stage.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/Mitts.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/mitts"
if [[ -f "$ROOT/icons/Mitts.icns" ]]; then cp "$ROOT/icons/Mitts.icns" "$STAGE/Contents/Resources/Mitts.icns"; fi
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Mitts</string>
<key>CFBundleDisplayName</key><string>Mitts</string>
<key>CFBundleExecutable</key><string>mitts</string>
<key>CFBundleIconFile</key><string>Mitts</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mike Cann</string>
</dict></plist>
PLIST

IDENTITY="${MITTS_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)}"
if [[ -z "$IDENTITY" ]]; then
  echo "No Apple Development identity; signing ad hoc, so macOS will ask for permissions again after every build." >&2
  IDENTITY=-
fi
# The default designated requirement (this identifier, signed by Mike's certificate) means
# the Accessibility and Screen Recording grants survive rebuilds, while a binary signed by
# anyone else can't claim them. Where Dat Space? relaxes it to the identifier alone; that
# would be too loose for an app that can drive the whole Mac.
codesign --force --timestamp=none --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$STAGE"
codesign --verify --strict "$STAGE"

if [[ -e "$APP" && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)" != "$BUNDLE_ID" ]]; then
  echo "Something else is at $APP. Move it first." >&2
  exit 1
fi
if [[ -e "$CLI" || -L "$CLI" ]] && [[ "$(readlink "$CLI" || true)" != "$APP/Contents/MacOS/mitts" ]]; then
  echo "Something else is at $CLI. Move it first." >&2
  exit 1
fi

# Stop the running copy so the next command starts the new one.
pkill -f "$APP/Contents/MacOS/mitts serve" 2>/dev/null || true
pkill -xf "$APP/Contents/MacOS/mitts" 2>/dev/null || true
mkdir -p "$(dirname "$APP")" "$(dirname "$CLI")"
rm -rf "$APP"
mv "$STAGE" "$APP"
ln -sfn "$APP/Contents/MacOS/mitts" "$CLI"
echo "Installed $APP, signed by $IDENTITY"
echo "\`mitts doctor\` starts it and says which permissions it still needs."
