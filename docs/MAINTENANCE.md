# 开发维护与更新

Swift 源码位于 Sources，网页 TypeScript/CSS 位于 Web，SQL schema 在 Store.swift，SQLite 包装在 DB.swift，接口合约见 API_CONTRACT.md。没有远程运行服务。

开发环境需要 macOS Command Line Tools。TypeScript 锁定开发工具版本 5.9.3；Swift 使用系统工具链，当前实测6.1.2。发布界面 app.js 已编译，最终用户不需要编译器。第三方运行时依赖数为零；系统 SQLite/FTS5、CryptoKit、AppKit、WebKit、Network、Security、PDFKit 使用 SDK 自带版本。

修改网页后执行 `scripts/check-web.sh` 严格 TypeScript 检查并生成 app.js，再执行 `scripts/build.sh`。开发工具包及 SHA-256 固定在 tools/DEPENDENCIES.lock.json；编译器只用于开发，不复制到 .app。部分本机 CLT 存在重复 SwiftBridging map，脚本生成工程内 VFS overlay，仅影响本次编译。不要改动 /Library/Developer 工具文件。

Tests/integration.py 调用真实打包二进制并创建隔离测试库；Tests/AITests.swift 为 AI 权限和索引隔离测试；Tests/ui-smoke.mjs 使用真实本地服务和浏览器；Tests/benchmark.py 验证1000/5000/10000元数据查询。AppKit/浏览器在受限代理沙箱中可能需要正常用户进程权限，最终普通桌面启动无需管理员。

发布时重新复制 Web、docs 和图标到 app，做 ad-hoc 签名、codesign --verify，记录 SHA-256，并运行一次最终二进制回归。任何源码更新不能跳过打包验证。正式跨设备分发如需 Apple Developer 签名/公证，需要用户自己的证书和开发者账户，本项目没有此凭据。

数据库变更递增 schema_migrations，设计前向兼容和备份恢复测试，不直接修改用户 blobs。版本化 blob 是不可变实体，外部编辑只能用工作副本。不要引入自动正文处理、未经授权外部请求、自动备份或默认登录启动。

手动更新：退出应用，运行新交付目录 Install.command，旧 app 会保留副本；个人库保持不变。没有自动在线更新机制。问题排查优先查看设置日志与完整性检查；日志不要添加 Key 或全文请求正文。
