#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ -d "$HOME/Applications/WorkVault.app" ]]; then
 /usr/bin/open "$HOME/Applications/WorkVault.app"
elif [[ -d "$PWD/dist/WorkVault.app" ]]; then
 /usr/bin/open "$PWD/dist/WorkVault.app"
else
 echo '请先双击 Install.command 安装。'; read -r '?按回车退出'
fi
