#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
SOURCE="$PWD/dist/WorkVault.app"
if [[ ! -d "$SOURCE" ]]; then SOURCE="$PWD/WorkVault.app"; fi
if [[ ! -d "$SOURCE" ]]; then echo '未找到 WorkVault.app，请保留完整交付目录。'; read -r '?按回车退出'; exit 1; fi
DEST="$HOME/Applications/WorkVault.app"
mkdir -p "$HOME/Applications"
if [[ -e "$DEST" ]]; then
  ANSWER=$(/usr/bin/osascript -e 'display dialog "将更新 WorkVault 应用程序。现有应用会保留副本，个人文件库不会删除。请先退出正在运行的 WorkVault。" buttons {"取消", "更新"} default button "更新"')
  if [[ "$ANSWER" != *'更新'* ]]; then exit 0; fi
  mv "$DEST" "$HOME/Applications/WorkVault.previous.$(date +%Y%m%d-%H%M%S).app"
fi
/usr/bin/ditto "$SOURCE" "$DEST"
/usr/bin/codesign --verify --deep --strict "$DEST"
/usr/bin/open "$DEST"
echo "已安装：$DEST"
