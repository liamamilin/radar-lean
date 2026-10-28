# Radar (v0.1, Lean R2)

macOS 原生信息雷达：自然语言建立关注 → 发现并试读信息源 → 定期直接采集 → 基线/去重 → 带原始链接的事件。

- 技术栈：SwiftUI · GRDB(SQLite) · FeedKit · SwiftSoup；无需任何 API Key（GitHub Token 可选，存钥匙串）。
- 构建：`scripts/build_app.sh` → `dist/Radar.app`（ad-hoc 签名，macOS 15+）。GRDB 以浅克隆放在 `ThirdParty/GRDB.swift`（官方仓库完整克隆在本机网络下过慢）。
- 测试：`swift test`（fixture + URLProtocol，A–F 六组行为）；真实联网：`RADAR_LIVE=1 swift test --filter LiveTests`。
- 数据库：`~/Library/Application Support/Radar/radar.sqlite`（环境变量 `RADAR_DB` 可覆盖）。

代码：`Sources/RadarCore`（Models/Fetch/Engine/Plan/Discovery）、`Sources/Radar`（SwiftUI App、菜单栏、设置）。

## Radar 开发结果
- 已实现：四种采集（GitHub Releases、GitHub 仓库发现、RSS/Atom、静态 HTML）；Watch–Source 基线（新 Watch 加入已初始化来源不补报）；Event 唯一键去重；ETag/304、403/429 限流、网络错误保存在 Source；自然语言建计划与后续调整（确定性规则，无法解析时提示手改）；来源试读与确认、Feed 自动发现、CSS 选择器预览；「追踪版本」；关注/更新/详情界面；菜单栏（打开、立即检查、暂停、最近事件、退出）；进程内 60 秒定时器 + 唤醒补查；系统通知；设置（GitHub Token）。
- 实际运行：`swift build -c release` 成功，`dist/Radar.app` 可启动，主窗口与菜单栏进程存活（用独立 DB 启动，窗口 900×612 在屏）。
- 已验证：12 项自动化测试全部通过（首次基线 0 事件、新稳定版 1 事件、重复 0、预发布被过滤、共享来源只抓一次且不补报、RSS 重排无事件、HTML 导航变更无事件/正文变更 1 事件含前后片段、304/429/断网区分、首次失败不置初始化、重启持久化、暂停不产生事件）。真实联网（RADAR_LIVE）：AI 主题输入 → 内置 `topic:ai-agents`/`topic:local-llm` 两个 GitHub 查询试读成功 → 60 个真实仓库入库，二次检查 0 事件、条目数不变；ollama/ollama 真实 Releases 基线 30 条 0 事件；swift.org 站点 URL 自动发现 atom.xml 并读取；swift.org 静态页正文提取成功。
- App 级验证（发布版 `dist/Radar.app`，独立 DB，真实联网，数据库驱动）：向空库写入 3 个关注（ollama/ollama Releases、swift.org atom、swift.org 安装页）并将来源设为到期 → App 启动后自动采集，3 个来源 `initialized=1`，条目 30/20/1，**0 事件**；随后删除最新正式版条目、最新文章、改动页面正文并清除 ETag → 定时器触发后恰好产生 3 条事件（Release 直链 `…/releases/tag/v0.40.12`、文章链接、页面前后片段）；再次到期检查无新增事件、无错误。
- 追加：未匹配内置目录的主题，若含英文关键词则生成可编辑的 GitHub 关键词搜索来源（先试读）；内置主题匹配改为整词，避免 detail/email 误判；菜单栏改为独立 View 以保证重新打开窗口可用；可选的 Foundation Models 计划解析（macOS 26+，本机 `deviceNotEligible`，**未能实测**，不可用时自动回退规则解析）。测试现为 15 项。
- 界面渲染验证：`RADAR_SNAPSHOT=<目录>` 开发开关会把窗口渲染成 PNG；已用上面的真实数据库看到「更新」列表（3 条带链接事件、网页前后片段）、关注详情（条件/来源状态）和新建关注面板正常渲染（输入与点击仍未实测）。
- 未完成或不可验证：**GUI 点击流程未实际操作**（本环境无辅助功能权限，无法驱动窗口/截图），三条用户流程是通过同一 Core 代码的测试验证，而非手点 UI；菜单栏“关闭窗口后仍可检查”仅确认进程与 MenuBarExtra 存在；通知未实测授权弹窗；Web 搜索 API 与 Foundation Models（第 4 轮）未做；JS 动态页仅给出不支持提示。
- 最值得继续优化：1) 实际点击走查三条流程并修 UI 细节；2) GitHub 仓库发现用「近 90 天创建、按 stars」窗口，新项目覆盖有限；3) 关键词中英文同义词目前只有小型别名表。

## 联网搜索信息源（新增）

设置里填 Exa API Key 后，主题类关注会先联网搜索，再对结果站点探测 RSS/Atom（按站点去重，跳过 GitHub 与社交站），探测通过的才作为候选列出。未填 key 时退回内置目录和 GitHub 搜索。已用 URLProtocol 桩测试；未用真实 key 实测（没有 key）。
