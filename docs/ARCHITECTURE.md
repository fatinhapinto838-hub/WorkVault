# 架构与数据模型

## 决策（2026-11-17）

目标机 macOS 15.8.3 / ARM64，约 68 GiB 可用磁盘。Swift 6.1.2 和 Command Line Tools 已安装，用户终端未安装 Node/Rust/Cargo。为避免安装 Rust、npm 依赖和独立后台运行时，采用 **Swift 原生 AppKit + WKWebView + Network HTTP + SQLite/FTS5**。TypeScript 严格模式用于开发期界面检查，发布的 JS/CSS/HTML 全部本地打包。没有远程 CDN、遥测、云数据库或模型自动下载。

这与建议 Tauri/React 栈有意不同：同样提供 .app 与本地浏览器管理界面，同时使用系统框架完成文件对话框、默认应用打开、Finder、PDFKit、CryptoKit 和 Keychain。最终运行只依赖 macOS 自带框架；开发依赖无需随应用安装。最低声明 macOS 15，实测设备仅 macOS 15.8.3，不宣称覆盖所有系统版本。

## 进程边界

一个 ARM64 原生进程拥有 NSApplication、WKWebView、本地 NWListener、文件监控计时器、SQLite 连接及可取消 AI 工作队列。服务随机端口绑定 127.0.0.1，退出最后一个窗口即退出服务。Ollama 是用户另行安装的可选独立服务，WorkVault 不在启动时拉起模型、不接管用户原有 Ollama 进程。

原生窗口和浏览器共用 JSON RPC 与流式上传/内容端点。随机启动 token 换取 HttpOnly SameSite=Strict 会话 cookie，随后重定向消除地址栏 token；Origin/Host 校验及 JSON 内容类型约束保护写操作。安全边界详见 SECURITY.md。

## 持久化

Store 管理 SQLite 关系表、内容寻址 blobs、不可变历史版本、可编辑工作副本、临时导入、日志和备份。单一文件二进制按 SHA-256 去重；文件记录与项目多对多。同名文件不自动合并版本；同标题不自动合并任务。用户显示标题与原始标题分别保留。来源记录包含类型、原始路径、原名、导入时间、可信度与状态。

事务、外键、唯一约束和迁移版本由 Store/DB 实现。文件复制使用有界分块，复制完成校验后原子重命名，数据库最后提交。源文件不删除。数据库错误可留下未引用 blob 供完整性检查，不能出现正常记录指向半文件。删除默认移入档案回收站，恢复保留历史。

## 收集适配层

所有入口转为统一 `importFile`/ImportJob/Provenance：手动选择、浏览器流式上传、目录批量导入、授权 Downloads、专用 Inbox、ZIP、官方导出元数据和手动标题链接。扫描只访问配置路径，排除符号链接及临时扩展名，文件连续稳定后才登记。未知来源保持待确认，不能冒充 Work。

## 检索与 AI

普通搜索仅数据库元数据，无启动全盘扫描。正文提取和全文 FTS 索引由用户单独触发；本地 Ollama 嵌入由额外显式选项触发。向量存于本地 SQLite JSON；混合检索使用词法与余弦评分，避免引入大型向量服务。这个实现适合个人库，向量扫描规模性能限制见测试报告。

DeepSeek 按官方 Chat Completions 协议使用 HTTPS；每个相关项目授权、请求预览确认、当前版本复查、可配置价格和预算、Keychain 密钥。费用是根据 Token 和配置价格的估计，不是账单。断网或没有 AI 不影响基本管理。

## 扩展与维护

RPC 合约在 API_CONTRACT.md，源码按 DB/Store/AIEngine/HTTPServer/main 与 Web 划分。修改 schema 需要递增迁移并验证旧库；保留用户库与程序目录分离。公开官方账户接口未来可用时才增加真正的适配器，不能将本地扫描标为账户同步。


## Schema 4：项目最终成果

`project_deliverables` 以项目、文件、版本为复合主键，并通过复合外键依赖 `file_projects`，引用不可变 `versions`。收录不复制 blob；同文件可在不同项目固定不同版本。合并/拆分保留收录，删除项目关联级联删除相应收录。API `deliverables` 分页项目或文件；`deliverable_set/remove/projects` 管理关系并记录事件。旧 final 标记作为兼容汇总字段，不再代替项目级收录。
