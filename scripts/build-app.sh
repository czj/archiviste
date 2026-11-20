#!/bin/zsh
# Build "Archiviste.app" (release), sign it ad hoc and install it in ~/Applications.
# Also installs the CLI as ~/.local/bin/archiviste.
#   scripts/build-app.sh [--no-install]
set -euo pipefail
ROOT="${0:A:h:h}"  # absolute: actool resolves relative paths against $PWD, not the cwd
cd "$ROOT"

swift build -c release --product ArchivisteApp
swift build -c release --product archiviste
BIN=$(swift build -c release --show-bin-path)

APP="$ROOT/build/Archiviste.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/ArchivisteApp" "$APP/Contents/MacOS/ArchivisteApp"
# Icon Composer icon (Liquid Glass layers) → Assets.car + AppIcon.icns
if ! xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
     --minimum-deployment-target 27.0 --app-icon AppIcon \
     --output-partial-info-plist "$ROOT/build/icon-partial.plist" > "$ROOT/build/actool.log"; then
  echo "✗ actool : voir build/actool.log" >&2
  exit 1
fi
# UI strings (French source, English) → fr.lproj and en.lproj
for catalog in Resources/Localizable.xcstrings Resources/InfoPlist.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done
codesign --force --sign - --timestamp=none "$APP"
echo "✓ $APP"

if [[ "${1:-}" != "--no-install" ]]; then
  mkdir -p ~/Applications ~/.local/bin
  pkill -x ArchivisteApp 2>/dev/null || true
  pkill -x PDFNamerApp 2>/dev/null || true  # the app's name up to 1.0
  rm -rf ~/Applications/"Archiviste.app" ~/Applications/"PDF Namer.app" ~/.local/bin/pdf-namer
  cp -R "$APP" ~/Applications/
  cp "$BIN/archiviste" ~/.local/bin/archiviste
  echo "✓ installé : ~/Applications/Archiviste.app et ~/.local/bin/archiviste"
fi
