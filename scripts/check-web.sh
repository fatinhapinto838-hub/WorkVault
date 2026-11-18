#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
if [[ -z "$NODE_BIN" && -x "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node" ]]; then
 NODE_BIN="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
fi
if [[ -z "$NODE_BIN" ]]; then echo '开发期检查需要 Node.js；最终应用运行不需要。'; exit 1; fi
EXPECTED=10e108c9cf7d5f2879053dff18515fb405abf2ccef63eaaf017d9c571687a1d3
ACTUAL=$(/usr/bin/shasum -a 256 tools/typescript-5.9.3.tgz | /usr/bin/awk '{print $1}')
if [[ "$ACTUAL" != "$EXPECTED" ]]; then echo 'TypeScript 工具包校验失败'; exit 1; fi
mkdir -p .build/typescript
/usr/bin/tar -xzf tools/typescript-5.9.3.tgz -C .build/typescript
"$NODE_BIN" .build/typescript/package/bin/tsc -p Web/tsconfig.json
"$NODE_BIN" --check Web/app.js
echo 'TypeScript strict 与 JS 语法检查通过'
