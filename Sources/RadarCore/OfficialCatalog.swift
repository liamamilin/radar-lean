import Foundation

/// Known official channels per company / product, each one checked by actually reading it (see docs/OFFICIAL-SOURCES.md).
/// A watch that mentions an entity gets its channels offered, and the watch page shows which ones are attached, missing or unreadable.
public struct OfficialChannel: Hashable {
    public var role: String          // 新闻 / 发布 / 更新日志 / 价格 / 状态 …
    public var spec: SourceSpec
    /// Attached automatically with a new watch. Status feeds are listed in the coverage report but only added on request: incident noise is not news.
    public var auto: Bool { role != "状态" }
    init(_ role: String, _ kind: SourceKind, _ endpoint: String, _ name: String, selector: String? = nil, every hours: Double = 4) {
        self.role = role; spec = SourceSpec(kind: kind, endpoint: endpoint, name: name, selector: selector, interval: hours * 3600)
    }
}

public struct UnreadableChannel: Hashable {
    public var name: String, url: String, reason: String
}

public struct OfficialEntity: Hashable {
    public var name: String
    public var aliases: [String]
    public var channels: [OfficialChannel]
    public var unreadable: [UnreadableChannel] = []
}

public enum OfficialCatalog {
    static let hfModels = "items=;id=id;title={id};url=https://huggingface.co/{id};summary={pipeline_tag} · ❤ {likes} · ⬇ {downloads};date=createdAt"

    public static let entities: [OfficialEntity] = [
        OfficialEntity(name: "OpenAI / ChatGPT / Codex", aliases: ["openai", "chatgpt", "codex", "gpt"], channels: [
            OfficialChannel("新闻", .rss, "https://openai.com/news/rss.xml", "OpenAI News（官方）", every: 1),
            OfficialChannel("发布", .githubReleases, "openai/codex", "openai/codex Releases", every: 2),
            OfficialChannel("更新日志", .web, "https://developers.openai.com/codex/changelog", "Codex Changelog（官方页面）", every: 4),
            OfficialChannel("价格 / 额度", .web, "https://developers.openai.com/codex/pricing", "Codex Pricing（官方页面）", every: 4),
            OfficialChannel("更新日志", .web, "https://developers.openai.com/api/docs/changelog", "OpenAI API Changelog（官方页面）", every: 6),
            OfficialChannel("状态", .rss, "https://status.openai.com/history.rss", "OpenAI Status（官方）", every: 1),
        ], unreadable: [
            UnreadableChannel(name: "ChatGPT 发布说明（帮助中心）", url: "https://help.openai.com/en/articles/6825453-chatgpt-release-notes", reason: "网站拦截自动化访问（HTTP 403），Radar 不绕过"),
            UnreadableChannel(name: "ChatGPT / API 官方定价页", url: "https://openai.com/chatgpt/pricing/", reason: "网站拦截自动化访问（HTTP 403），Radar 不绕过"),
        ]),
        OfficialEntity(name: "Anthropic / Claude", aliases: ["anthropic", "claude", "claude code"], channels: [
            OfficialChannel("新闻", .list, "https://www.anthropic.com/news", "Anthropic News（官方）", every: 2),
            OfficialChannel("工程博客", .list, "https://www.anthropic.com/engineering", "Anthropic Engineering（官方）", every: 6),
            OfficialChannel("发布", .githubReleases, "anthropics/claude-code", "anthropics/claude-code Releases", every: 2),
            OfficialChannel("更新日志", .web, "https://docs.claude.com/en/docs/claude-code/changelog", "Claude Code Changelog（官方页面）", every: 4),
            OfficialChannel("更新日志", .web, "https://docs.claude.com/en/release-notes/api", "Claude API Release Notes（官方页面）", every: 6),
            OfficialChannel("价格", .web, "https://claude.com/pricing", "Claude Pricing（官方页面）", every: 6),
            OfficialChannel("状态", .rss, "https://status.claude.com/history.rss", "Claude Status（官方）", every: 1),
        ]),
        OfficialEntity(name: "Ollama", aliases: ["ollama"], channels: [
            OfficialChannel("新闻", .rss, "https://ollama.com/blog/rss.xml", "Ollama Blog（官方）", every: 4),
            OfficialChannel("发布", .githubReleases, "ollama/ollama", "ollama/ollama Releases", every: 2),
        ]),
        OfficialEntity(name: "Cursor", aliases: ["cursor"], channels: [
            OfficialChannel("更新日志", .list, "https://cursor.com/changelog", "Cursor Changelog（官方）", every: 6),
        ], unreadable: [
            UnreadableChannel(name: "Cursor 定价页 / 状态页", url: "https://cursor.com/pricing", reason: "试读到的内容与 Cursor 无关（出现 Grok / 社交功能的价格），已确认不可信，未接入"),
        ]),
        OfficialEntity(name: "GitHub Copilot", aliases: ["copilot", "github copilot"], channels: [
            OfficialChannel("更新日志", .rss, "https://github.blog/changelog/label/copilot/feed/", "GitHub Copilot Changelog（官方）", every: 4),
            OfficialChannel("价格", .web, "https://github.com/features/copilot/plans", "Copilot Plans（官方页面）", every: 6),
        ]),
        OfficialEntity(name: "Windsurf", aliases: ["windsurf"], channels: [
            OfficialChannel("更新日志", .list, "https://windsurf.com/changelog", "Windsurf Changelog（官方，需渲染）", selector: "js:", every: 12),
        ]),
        OfficialEntity(name: "Hugging Face", aliases: ["hugging face", "huggingface"], channels: [
            OfficialChannel("新闻", .rss, "https://huggingface.co/blog/feed.xml", "Hugging Face Blog（官方）", every: 6),
            OfficialChannel("热门新模型", .json, "https://huggingface.co/api/models?sort=trendingScore&direction=-1&limit=30", "Hugging Face 趋势模型（官方接口）", selector: hfModels, every: 6),
            OfficialChannel("发布", .githubReleases, "huggingface/transformers", "huggingface/transformers Releases", every: 6),
        ]),
    ]

    /// Entities mentioned in some text (a watch's sentence, title or keywords).
    public static func entities(in text: String) -> [OfficialEntity] {
        entities.filter { Keywords.matches(text, any: $0.aliases) }
    }
}
