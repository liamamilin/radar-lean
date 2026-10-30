# 官方信息源目录

Radar 内置了一份“官方渠道”目录（代码在 `Sources/RadarCore/OfficialCatalog.swift`）。关注里提到某个产品或公司时，Radar 会自动试读并接入它的官方渠道，在关注详情页的“官方来源覆盖”里显示哪些已接入、哪些没接、哪些读不了。

每个渠道都用 Radar 自己的读取代码实际试读过（2026-10-30），**只有读到真实内容的才收录**。“状态页”不会自动接入（故障通报很多，不算新闻），可在覆盖报告里手动添加。

## 已收录

| 实体 | 渠道 | 类型 | 说明 |
| --- | --- | --- | --- |
| OpenAI / ChatGPT / Codex | OpenAI News | RSS | 官方新闻 |
| | openai/codex | GitHub Releases | Codex 版本 |
| | Codex Changelog | 网页变化 | 更新日志页 |
| | Codex Pricing | 网页变化 | 价格 / 额度页，额度改动会显示前后片段 |
| | OpenAI API Changelog | 网页变化 | API 更新日志 |
| | OpenAI Status | RSS（手动添加） | 故障通报 |
| Anthropic / Claude | Anthropic News | 列表页 | 官方新闻 |
| | Anthropic Engineering | 列表页 | 工程博客 |
| | anthropics/claude-code | GitHub Releases | Claude Code 版本 |
| | Claude Code Changelog | 网页变化 | 更新日志 |
| | Claude API Release Notes | 网页变化 | API 发布说明 |
| | Claude Pricing | 网页变化 | 价格页 |
| | Claude Status | RSS（手动添加） | 故障通报 |
| Ollama | Ollama Blog | RSS | 官方博客 |
| | ollama/ollama | GitHub Releases | 版本 |
| Cursor | Cursor Changelog | 列表页 | 更新日志 |
| GitHub Copilot | Copilot Changelog | RSS | 官方更新日志（Copilot 标签） |
| | Copilot Plans | 网页变化 | 套餐与价格 |
| Windsurf | Windsurf Changelog | 列表页（需 JS 渲染） | 更新日志 |
| Hugging Face | Hugging Face Blog | RSS | 官方博客 |
| | 趋势模型 | JSON 接口 | 官方 API 的趋势模型前 30 |
| | huggingface/transformers | GitHub Releases | 版本 |

## 已知读不了或不可信（Radar 的盲区）

| 渠道 | 原因 |
| --- | --- |
| ChatGPT 发布说明（help.openai.com） | 网站拦截自动化访问（HTTP 403）。Radar 不伪装浏览器绕过。 |
| ChatGPT / API 官方定价页（openai.com） | 同上（HTTP 403）。 |
| Cursor 定价页 / 状态页 | 读到的内容和 Cursor 无关（出现 Grok / 社交功能价格），无法确认是官方内容，没有接入。 |
| 社交账号（X 等）、需要登录的页面 | 无法读取。 |

## 怎么补充

- 在 `OfficialCatalog.swift` 里加一个实体或渠道，先用 Radar 试读，读到真实内容再提交。
- 渠道类型可以是 RSS、GitHub Releases、网页变化、列表页、JSON 接口；需要 JavaScript 渲染的页面，把选择器写成 `js:`（或 `js:<CSS 选择器>`）。
- JSON 接口用字段映射描述，例如 `items=vulnerabilities;id=cveID;title={cveID} · {vendorProject};url=https://nvd.nist.gov/vuln/detail/{cveID};date=dateAdded`。
- 渲染遇到人机验证页面时，Radar 会报“网站要求人机验证，Radar 不会绕过”，不会继续。
