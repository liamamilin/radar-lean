import Foundation

/// What a new item means depends on what the source actually is: an official feed, a community board, a model list.
extension Engine {
    /// A new article / list item. An official channel's post that never names what the watch follows is recorded, but only pricing or
    /// the user's own focus words can make it more than an ordinary update.
    static func judgeArticle(plan: WatchPlan, kind: SourceKind, entry: Entry, about: Bool, official: Bool = false) -> Judged {
        let t = entry.title.lowercased()
        if isPricingNews(entry.title) { return Judged(reason: "价格 / 额度 / 套餐相关", kind: "majorUpdate") }
        if let f = plan.focus, !f.isEmpty, Keywords.matches(entry.title, any: f) {
            return Judged(reason: "命中你关注的内容（\(f.joined(separator: "、"))）", kind: "majorUpdate")
        }
        guard about else { return Judged(reason: "官方来源新内容（没有提到关注对象）", kind: "update") }
        // an official feed also carries customer stories ("X cuts launch hours by 68%"): only a title that announces something counts
        let announces = ["introducing", "launching", "launch ", "announcing", "releasing", "release ", "new ", "now available", "is here"].contains { t.hasPrefix($0) }
        let major = official ? announces : majorWords.contains { t.contains($0) }
        return Judged(reason: kind == .list ? "列表页新条目" : "新文章", kind: major ? "majorUpdate" : "update")
    }

    /// Hacker News: a launch is a "Show HN" / "Launch HN" post that links somewhere other than HN itself and has real votes.
    /// A keyword in a title proves nothing about a project being new.
    static func judgeHackerNews(_ e: Entry) -> Judged {
        let pts = Int(e.meta["points"] ?? "") ?? 0, comments = Int(e.meta["comments"] ?? "") ?? 0
        let t = e.title.lowercased()
        let external = URL(string: e.canonicalURL)?.host?.hasSuffix("ycombinator.com") == false
        let repo = PlanParser.githubRepo(e.canonicalURL)
        let tail = "HN \(pts) 分 · \(comments) 条评论"
        if (t.hasPrefix("show hn") || t.hasPrefix("launch hn")) && external && pts >= 20 {
            return Judged(reason: "作者发布的新项目 / 工具（\(repo.map { "GitHub \($0)" } ?? "Show HN")）· \(tail)", kind: "newProject")
        }
        if isPricingNews(e.title) && pts >= 20 { return Judged(reason: "价格 / 额度 / 套餐相关 · \(tail)", kind: "majorUpdate") }
        if pts >= 100, ["release", "released", "launch", "launches", "introducing", "announcing"].contains(where: { t.contains($0) }) {
            return Judged(reason: "社区热议的发布 · \(tail)", kind: "majorUpdate")
        }
        if let repo { return Judged(reason: "社区讨论的项目：\(repo)（不一定是新项目）· \(tail)", kind: "update") }
        return Judged(reason: t.hasPrefix("ask hn") ? "社区提问 · \(tail)" : "社区讨论 · \(tail)", kind: "update")
    }

    static let languageModelPipelines: Set<String> = ["text-generation", "image-text-to-text", "any-to-any", "text2text-generation",
                                                       "video-text-to-text", "audio-text-to-text", "conversational"]

    /// Hugging Face model lists. Being on a trending list says nothing about when a model was released; `createdAt` does.
    static func judgeModel(plan: WatchPlan, entry e: Entry, change: Change, now: Date) -> Judged? {
        let pipe = e.meta["pipeline_tag"] ?? "", tags = (e.meta["tags"] ?? "").lowercased()
        let hay = e.title + " " + e.summary
        guard languageModelPipelines.contains(pipe) || (!plan.include.isEmpty && Keywords.matches(hay + " " + tags, any: plan.include)),
              plan.exclude.isEmpty || !Keywords.matches(hay, any: plan.exclude) else { return nil }
        let likes = Int(e.meta["likes"] ?? "") ?? 0, downloads = Int(e.meta["downloads"] ?? "") ?? 0
        guard let created = e.publishedAt ?? Fetcher.iso.date(from: e.meta["createdAt"] ?? "") else { return nil }
        let age = max(0, now.timeIntervalSince(created) / 86400)
        let local = (tags.contains("gguf") || e.meta["library_name"] == "gguf" || tags.contains("mlx") || tags.contains("ollama"))
            ? "本地部署：有 GGUF / MLX 等量化版本" : "本地部署：未确认"
        // a quantised / uncensored / merged copy of someone else's model is not a new model
        let derivative = Keywords.matches(e.title, any: ["gguf", "awq", "gptq", "abliterat", "uncensored", "quantized", "mlx", "fp8", "int4", "merge"])
        var size = ""
        if let r = e.title.range(of: #"(?<![A-Za-z0-9.])(\d+(\.\d+)?)\s?([BbTt])(?![A-Za-z])"#, options: .regularExpression) {
            let t = String(e.title[r]).uppercased().replacingOccurrences(of: " ", with: "")
            let n = Double(t.dropLast()) ?? 0
            let big = t.hasSuffix("T") || n >= 200
            size = " · 参数量约 \(t)（按名称推断）" + (big ? "，体量很大，本地部署困难" : "")
        }
        let facts = "创建于 \(Int(age)) 天前 · ❤ \(likes) · ⬇ \(downloads) · \(local)\(size)"
        let bar = age <= 14 ? 30 : 200
        switch change {
        case .new:
            if derivative && age <= 14 { return Judged(reason: "衍生 / 量化版本（不是新模型）· \(facts)", kind: "update") }
            if age <= 14 { return Judged(reason: "新模型 · \(facts)", kind: likes >= bar ? "newProject" : "update") }
            if age <= 60 && likes >= bar { return Judged(reason: "进入趋势榜（不是新发布）· \(facts)", kind: "update") }
            return nil
        case .metrics(let prev):
            let was = Int(prev["likes"] ?? "") ?? 0
            guard age <= 60, likes >= bar, was < bar else { return nil }
            return Judged(reason: "模型升温 · ❤ \(was) → \(likes) · \(facts)", kind: "newProject")
        case .changed: return nil
        }
    }
}
