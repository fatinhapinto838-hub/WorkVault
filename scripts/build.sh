#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build
APP="$PWD/dist/WorkVault.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Web"
# Work around duplicate legacy SwiftBridging map in some CLT installations,
# using a compiler-only virtual filesystem overlay; never change system files.
EXTRA=()
LEGACY=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
CURRENT=/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap
if [[ -f "$LEGACY" && -f "$CURRENT" ]]; then
  : > .build/empty.modulemap
  /usr/bin/python3 - "$PWD" <<'PYOVERLAY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
(root/'.build/overlay.json').write_text(json.dumps({'version':0,'roots':[{'type':'file','name':'/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap','external-contents':str(root/'.build/empty.modulemap')}]}))
PYOVERLAY
  EXTRA=(-vfsoverlay "$PWD/.build/overlay.json" -Xcc -ivfsoverlay -Xcc "$PWD/.build/overlay.json")
fi
swiftc "${EXTRA[@]}" -O -swift-version 5 -I CSQLite -module-cache-path "${WORKVAULT_MODULE_CACHE:-.build/module-cache}" Sources/*.swift -o "$APP/Contents/MacOS/WorkVault" -framework AppKit -framework WebKit -framework Network -framework Security -framework PDFKit -lsqlite3
cp Web/index.html Web/app.js Web/styles.css "$APP/Contents/Resources/Web/"
cp -R docs "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>WorkVault</string>
<key>CFBundleDisplayName</key><string>WorkVault</string>
<key>CFBundleIdentifier</key><string>local.WorkVault</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleExecutable</key><string>WorkVault</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>WorkVault</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
if [[ -f assets/WorkVault.icns ]]; then cp assets/WorkVault.icns "$APP/Contents/Resources/"; fi
codesign --force --deep --sign - "$APP"
echo "$APP"
