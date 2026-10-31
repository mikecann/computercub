#!/usr/bin/env bash
# Builds ComputerCub.app, signs it, installs it to ~/Applications and links `computercub` onto PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${COMPUTERCUB_APP_PATH:-$HOME/Applications/ComputerCub.app}"
CLI="${COMPUTERCUB_CLI_PATH:-$HOME/.local/bin/computercub}"
BUNDLE_ID='app.mikecann.computercub'
cd "$ROOT"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/computercub"
STAGE_ROOT="$(mktemp -d "$ROOT/.build/stage.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/ComputerCub.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/computercub"
# icons/computercub.png is the 1024 px app icon.
mkdir -p "$STAGE_ROOT/icon.iconset"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/icons/computercub.png" --out "$STAGE_ROOT/icon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/icons/computercub.png" --out "$STAGE_ROOT/icon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$STAGE_ROOT/icon.iconset" -o "$STAGE/Contents/Resources/ComputerCub.icns"
# The bear that peers over the window an agent is in.
cp "$ROOT/icons/peek.png" "$STAGE/Contents/Resources/peek.png"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>ComputerCub</string>
<key>CFBundleDisplayName</key><string>ComputerCub</string>
<key>CFBundleExecutable</key><string>computercub</string>
<key>CFBundleIconFile</key><string>ComputerCub</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mike Cann</string>
</dict></plist>
PLIST

IDENTITY="${COMPUTERCUB_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)}"
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
if [[ -e "$CLI" || -L "$CLI" ]] && [[ "$(readlink "$CLI" || true)" != "$APP/Contents/MacOS/computercub" ]]; then
  echo "Something else is at $CLI. Move it first." >&2
  exit 1
fi

# Stop the running copy so the next command starts the new one.
pkill -f "$APP/Contents/MacOS/computercub serve" 2>/dev/null || true
pkill -xf "$APP/Contents/MacOS/computercub" 2>/dev/null || true
mkdir -p "$(dirname "$APP")" "$(dirname "$CLI")"
rm -rf "$APP"
mv "$STAGE" "$APP"
ln -sfn "$APP/Contents/MacOS/computercub" "$CLI"
# The agent skill, so Claude and Codex know to reach for `computercub`.
for SKILLS in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
  LINK="$SKILLS/computercub"
  if [[ -e "$LINK" || -L "$LINK" ]] && [[ "$(readlink "$LINK" || true)" != "$ROOT/skill" ]]; then
    echo "Something else is at $LINK; leaving it." >&2
  elif [[ -d "$SKILLS" ]]; then
    ln -sfn "$ROOT/skill" "$LINK"
  fi
done
echo "Installed $APP, signed by $IDENTITY"
echo "\`computercub doctor\` starts it and says which permissions it still needs."
