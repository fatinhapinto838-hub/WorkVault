#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build Tests/results work
EXTRA=()
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap && -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ]]; then
  : > .build/empty.modulemap
  /usr/bin/python3 - "$PWD" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])
(p/'.build/finder-overlay.json').write_text(json.dumps({'version':0,'roots':[{'type':'file','name':'/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap','external-contents':str(p/'.build/empty.modulemap')}]}))
PY
  EXTRA=(-vfsoverlay "$PWD/.build/finder-overlay.json" -Xcc -ivfsoverlay -Xcc "$PWD/.build/finder-overlay.json")
fi
swiftc -O -swift-version 5 "${EXTRA[@]}" -module-cache-path "${WORKVAULT_MODULE_CACHE:-.build/module-cache}" -I CSQLite Sources/DB.swift Sources/Store.swift Sources/Deliverables.swift Tests/FinderTests.swift -o .build/FinderTests -framework AppKit -framework PDFKit -lsqlite3
.build/FinderTests > Tests/results/finder-test-results.json
cat Tests/results/finder-test-results.json
