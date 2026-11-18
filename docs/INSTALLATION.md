# macOS 安装与启动

目标为 Apple Silicon Mac，最低构建目标 macOS 15（仅在 15.8.3 实测）。最终应用使用系统框架，无需 Node、Rust、Python、Docker 或云服务器。源代码编译仍需要 Xcode Command Line Tools。

1. 解压完整交付包，双击 `Install.command`。程序复制至 `~/Applications/WorkVault.app` 并打开。若已存在同名应用，安装器先询问并保留旧程序副本。
2. 也可以直接打开 `dist/WorkVault.app`，或把它拖入用户 Applications 文件夹。
3. 首次使用完成九步引导，选择永久存储位置。默认 `~/Documents/WorkVault`；授权监控、AI、开机启动全部可跳过。
4. 后续从 Launchpad、Finder、Spotlight 或 `Launch.command` 打开。可以把应用拖至 Dock。
5. 菜单“在浏览器中打开”或设置中的对应入口提供本机网页访问。端口每次启动随机，不应固定收藏旧地址。
6. 关闭最后一个应用窗口，或按 ⌘Q，或设置“退出并停止服务”会退出本地服务。浏览器单独关闭页面不会退出原生应用。

本构建使用本地 ad-hoc 签名，**没有 Apple Developer 身份签名或 Apple 公证**。从其他设备下载后 macOS 可能提示无法验证开发者；确认包来源后可在 Finder 右键打开，或在系统设置“隐私与安全性”按系统提供的“仍要打开”流程处理。不要关闭 Gatekeeper 或 SIP。安装器不自动移除系统隔离属性。

## 登录时启动

默认关闭。设置中启用后，在用户 `~/Library/LaunchAgents/local.WorkVault.login.plist` 创建用户级登录启动配置，下次登录生效，不需要管理员权限。关闭后删除该配置。它只在登录时打开应用，不设置崩溃无限重启。

## 卸载

先退出 WorkVault，再在设置关闭登录启动，最后将 `~/Applications/WorkVault.app` 移至废纸篓。若忘记关闭，可在 Finder 前往 `~/Library/LaunchAgents`，只删除 `local.WorkVault.login.plist`。**不要删除文件库**，即可保留所有项目和版本。用户默认目录、备份及 Keychain 项不随卸载清理。若希望删除 DeepSeek 密钥，先在设置专用入口清除它。

## 开发构建

运行 `scripts/build.sh`；TypeScript 修改后先运行 Web 的严格检查构建脚本。本机 CLT 存在重复 SwiftBridging 模块声明，构建脚本使用项目内 VFS 覆盖配置隐藏重复声明，不修改系统工具。新机器若没有该问题不需要覆盖。
