# ChatGPT / Work 集成技术验证

验证日期：2026-11-17（Asia/Shanghai）。范围：个人本地 macOS WorkVault 应用，非企业管理员。以下区分文档证据、当前会话工具实测和独立软件接口；不将“不曾找到文档”写成对未来永久不存在的断言。

## 官方证据与结果

| 能力 | 官方来源 / 访问方式 | 权限、适用账户 | 本次实际结果 | 分类 / 维护风险 |
|---|---|---|---|---|
| 普通个人 Work 任务列表、文件列表/下载 API、标题读取 API、文件更新事件 | [Work 概览](https://learn.chatgpt.com/docs/enterprise/chatgpt-work-overview)、[桌面应用](https://learn.chatgpt.com/docs/app)、[文件体验](https://learn.chatgpt.com/docs/artifacts-viewer) | 未找到第三方个人账户 OAuth scope / SDK / 稳定公开端点 | 检索官方文档，没有可交付给独立 WorkVault 的正式账户连接接口；未访问任何私有端点 | 当前不可用；不可伪称同步成功 |
| 当前 Codex/Work 工具环境列举 ChatGPT 会话 | 本次已提供的官方 `codex-app-tools.list_threads`，source=chatgpt | 仅当前已授权助手环境，不是独立应用公共 SDK | 实际返回 3 个真实会话 id、title、updatedAt；没有可靠 Work/Chat 类型和附件下载字段。未导入这些私人会话，也未读取私有数据库 | 环境内已验证可用；不随 .app 分发、不把会话都认定为 Work |
| 账户官方数据导出 | [导出指南](https://help.openai.com/en/articles/7260999-exporting-your-chatgpt-history-and-data) | 用户自行在 Settings/Data controls 或 Privacy Portal 请求；普通个人符合条件账户可用；部分托管工作区不可自行导出 | 官方描述 JSON 会话、其他格式元数据及导出查看器。没有用户真实导出包，因此代码用结构化测试样本验证兼容性，不宣称真实附件齐全 | 需用户授权、需要手动辅助；结构版本可能变化 |
| Library / Space 文件 | [Library](https://help.openai.com/en/articles/20001052-using-library-to-manage-files-in-chatgpt)、[文件存储](https://help.openai.com/en/articles/20001052-file-storage-and-library-in-chatgpt) | 用户界面下载；特定企业管理员 Compliance 接口 | 官方说明用户可下载文件，部分账户 UI 由 Space 替代 Library；未找到个人第三方全库读取授权 API | 需要手动辅助；不混用企业接口 |
| OpenAI 平台 Files / Conversations API | [Files API](https://developers.openai.com/api/reference/resources/files)、[Conversations](https://developers.openai.com/api/reference/resources/conversations/methods/create) | API 平台密钥与 API 项目权限 | 此类接口管理 API 项目资源，不证明可读取 ChatGPT Plus 历史；WorkVault 不调用 | 不适用于本需求个人账户同步 |
| 本地文件夹写入 | [Projects and chats](https://learn.chatgpt.com/docs/projects)、[桌面应用](https://learn.chatgpt.com/docs/app) | 用户授予本地项目目录访问；平台和工作区策略限制 | 当前任务实际在授权本地目录创建本工程，证明本会话可写入允许目录。并不证明所有 ChatGPT Work 任务默认写入同一目录 | 已验证当前环境可用；每个任务仍须明确保存指令 |
| 本地 Work / 云端 Work | [Work 概览](https://learn.chatgpt.com/docs/enterprise/chatgpt-work-overview)、[本地计算机访问](https://learn.chatgpt.com/docs/enterprise/cloud-local-access) | 云端访问本地需支持的配置、权限及在线计算机 | 云容器不自动继承本地文件；会话同步不等于本地目录上传或附件同步。企业配置文档不能证明当前个人账户可用全部企业能力 | 文档验证；当前个人账户云端权限未做联调 |
| 客户端分享/本地固定保存目录 | 同上及[文件体验](https://learn.chatgpt.com/docs/artifacts-viewer) | 按界面功能和文件访问权限 | 官方支持预览/下载和本地项目目录；未证实统一的所有 Work 成果固定目录或面向第三方的系统分享扩展协议 | 手动下载/拖拽可靠；不依赖未证实固定目录 |

## 实现边界

WorkVault 的“扫描”仅指已授权本地来源，不表示已登录 ChatGPT。任务标题来自用户输入、用户提供的会话链接/ID、官方导出中的原始 title 或显式保存的本地元数据。文件名只作检索元数据，不能冒充真实会话标题。没有 ID 的同名任务不会自动合并。普通导出会话类型不明确时保留待确认来源，附件缺失显示需补原文件。

推荐流程：创建 WorkVault-Inbox → 在可访问本地目录的 Work 任务中明确要求把最终成果保存到该目录 → WorkVault 轻量登记 → 用户关联项目；或从 Library/Space 下载后拖拽导入。历史标题通过官方导出向导补充。原始下载文件不修改、不删除。

自动读取全部云端任务标题和完整文件实体目前不作为已完成能力。没有 cookie/token 抓取、私有协议逆向、ChatGPT 密码输入、浏览器/钥匙串扫描、后台屏幕抓取。DeepSeek Keychain 仅访问 WorkVault 自己的服务项。

## 可重复验证

1. 用户自行打开官方页面确认账户功能，下载官方导出包。
2. 导出向导先检查真实 JSON 结构，不强制依赖单一版本。
3. 检查项目 title_source、conversation_id 和来源可信度。
4. 缺失文件只登记元数据，不构造附件或伪造页码。
5. 本地目录监控开启前选择路径；未开启时不存在后台扫描。

未进行：真实个人云端 Work 账户 API 联调（没有公开接口）、用户真实导出包、企业 Compliance API、云端任务对本地保存目录权限测试。以上不能用模拟测试代替。
