# WorkVault

本地运行的 ChatGPT Work 成果管理中心。Apple Silicon 原生 Swift 应用 + 离线中文网页界面 + SQLite，文件和历史版本永久保存在自选本地目录。基础管理没有服务器、云数据库、订阅或 AI 依赖。

当前版本 **1.2.3** 提供独立的「最终成果」栏目，按真实交付时间倒序排列项目和文件；缺少交付时间时明确使用收录时间。固定交付版本，可预览、打开、导出及在 Finder 中显示、添加和移出，复用原文件实体。详见 [最终成果使用说明](docs/FINAL_DELIVERABLES.md)。

「最终成果」按项目名称或原始任务标题搜索，点击项目即可查看最终成果。「文件中心」返回文件，关键词搜索排除 `.md` / `.markdown`。清除关键词后可继续浏览 Markdown 档案。

## 使用

双击 **Install.command** 安装至用户 Applications 并启动；日常打开 **WorkVault.app** 或 **Launch.command**。首次完成九步引导，默认库建议 `~/Documents/WorkVault`。下载监控、登录启动、本地 AI 和 DeepSeek 均默认关闭。

本构建为本机 ad-hoc 签名，未经 Apple Developer 身份签名或公证。目标 ARM64 / macOS15，实测15.8.3。安装无需开发环境。

- 管理：文件/目录/拖拽/ZIP导入、SHA-256去重、多项目关联、真实来源、待确认收件箱、项目标题/原始标题/会话ID、分类标签、收藏/最终成果、元数据搜索、Office简化预览/PDF/图片/文本、外部工作副本编辑登记、不可变版本、回收站。
- 收集：明确授权的目录稳定扫描、本地任务清单自动关联、官方导出标题/缺失附件索引。**不声称连接个人 ChatGPT Work 公开账户接口**。
- 数据：手动SHA备份、独立恢复、校验迁移保留旧库、已有库切换、外置存储不可用提示。
- AI：手动索引+FTS5+可选本地嵌入，Ollama/DeepSeek主动分析，RAG问答与真实引用，Keychain、逐项目授权、发送预览、预算和取消。没有配置模型/密钥也可管理文件。

真实验收结果和边界见 [已知限制](docs/KNOWN_LIMITATIONS.md)。不要把实现代码和隔离测试当作真实云端接口或模型联调。

## 文档

- [官方集成能力验证](docs/CHATGPT_INTEGRATION_FEASIBILITY.md)
- [安装和卸载](docs/INSTALLATION.md)
- [中文用户手册](docs/USER_GUIDE.md)
- [任务标题清单](docs/WORK_TITLE_MANIFEST.md)
- [AI配置](docs/AI_CONFIGURATION.md)
- [备份恢复](docs/BACKUP_AND_RESTORE.md)
- [目录迁移](docs/DATA_MIGRATION.md)
- [架构](docs/ARCHITECTURE.md) / [存储格式](docs/STORAGE_FORMAT.md)
- [安全隐私](docs/SECURITY.md) / [维护](docs/MAINTENANCE.md)
- [性能基准](docs/PERFORMANCE.md)

## 开发

```sh
scripts/build.sh
```

源码：Sources / Web，发布 app：dist。无第三方运行库。TS开发工具固定5.9.3，strict检查；发布JS已经生成。CLT重复模块问题仅用工程内VFS配置处理，不改系统。

测试：Tests/deliverables.py、Tests/final-ui-smoke.mjs、Tests/integration.py、Tests/AITests.swift、Tests/ui-smoke.mjs、Tests/benchmark.py。全部隔离测试，不给用户库灌入合成数据。
