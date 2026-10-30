import Foundation

public struct Version: Comparable {
    var nums: [Int]
    var pre: String?
    public init?(_ s: String) {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("v") { t.removeFirst() }
        guard let m = t.range(of: #"^\d+(\.\d+){0,2}"#, options: .regularExpression) else { return nil }
        nums = t[m].split(separator: ".").compactMap { Int($0) }
        while nums.count < 3 { nums.append(0) }
        let rest = t[m.upperBound...]
        if rest.isEmpty { pre = nil }
        else if rest.hasPrefix("-") || rest.hasPrefix("+") {
            if rest.hasPrefix("+") { pre = nil } else { pre = String(rest.dropFirst()) }
        } else { return nil }
    }
    public static func < (a: Version, b: Version) -> Bool {
        if a.nums != b.nums { return a.nums.lexicographicallyPrecedes(b.nums) }
        switch (a.pre, b.pre) {
        case (nil, nil): return false
        case (nil, _): return false   // release > prerelease
        case (_, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }
}

public enum PlanParser {
    static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s，。,；;)）>"']+"#)

    public static func url(in text: String) -> String? {
        let r = NSRange(text.startIndex..., in: text)
        guard let m = urlRegex.firstMatch(in: text, range: r), let rr = Range(m.range, in: text) else { return nil }
        return String(text[rr])
    }

    /// owner/repo if the URL points to a GitHub repository.
    public static func githubRepo(_ urlString: String) -> String? {
        guard let u = URL(string: urlString), let h = u.host?.lowercased(), h == "github.com" || h == "www.github.com" else { return nil }
        let p = u.pathComponents.filter { $0 != "/" }
        guard p.count >= 2 else { return nil }
        var repo = p[1]; if repo.hasSuffix(".git") { repo.removeLast(4) }
        return "\(p[0])/\(repo)"
    }

    static func minimumVersion(in text: String) -> String? {
        let pats = [#"[vV]?(\d+(?:\.\d+){0,2})\s*(?:以上|或更高|及以上|或以上|之后|以后|\+|or higher|or newer|and above|and later)"#,
                    #"(?:≥|>=|最低版本|最低|至少|大于等于|不低于)\s*[vV]?(\d+(?:\.\d+){0,2})"#,
                    #"(?:at least|minimum|min)\s*[vV]?(\d+(?:\.\d+){0,2})"#]
        for p in pats {
            if let m = text.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let s = String(text[m])
                if let n = s.range(of: #"\d+(\.\d+){0,2}"#, options: .regularExpression) { return String(s[n]) }
            }
        }
        return nil
    }

    static func minStars(in text: String) -> Int? {
        let p = #"(?:stars?|星标|星星|★)\s*(?:>=|≥|超过|大于|至少|不少于|over|above)?\s*(\d+)\s*(?:以上|\+)?|(?:超过|至少|不少于|over|above)\s*(\d+)\s*(?:个)?\s*(?:stars?|星标|星星|★)"#
        guard let r = text.range(of: p, options: [.regularExpression, .caseInsensitive]),
              let n = String(text[r]).range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(String(text[r])[n])
    }

    /// Conditions we understand as requests but cannot judge automatically; shown to the user instead of silently ignored.
    static let semanticMarkers = ["创新", "有趣", "新手友好", "适合初学者", "适合新手", "易用", "好用", "权威", "商用", "可商用", "免费", "国产", "中文",
                                  "生产可用", "成熟", "性能好", "性能更好", "轻量", "文档完善", "社区活跃", "大厂", "靠谱"]
    static func unsupportedConditions(in text: String) -> [String] {
        semanticMarkers.filter { text.contains($0) }.map { "「\($0)」：无法自动判断，未生效" }
    }

    static func splitList(_ s: String) -> [String] {
        var t = s
        for sep in ["，", ",", "、", "；", ";", "以及", "还有", " and ", "和", "及", "与", "/"] { t = t.replacingOccurrences(of: sep, with: "|") }
        return t.split(separator: "|").map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "+#."))) }
            .filter { !$0.isEmpty }
    }

    /// Text after any of the markers, up to a clause break.
    static func clause(after markers: [String], in text: String) -> String? {
        for m in markers {
            if let r = text.range(of: m, options: .caseInsensitive) {
                var rest = String(text[r.upperBound...])
                if let end = rest.firstIndex(where: { "。.;；\n".contains($0) }) { rest = String(rest[..<end]) }
                let cut = ["，排除", ",排除", "，不要", "，除了", ", exclude", "，尤其", "，优先", "，特别"]
                for c in cut { if let cr = rest.range(of: c) { rest = String(rest[..<cr.lowerBound]) } }
                // a trailing "，有……时提醒我" style clause is the alert condition, not a keyword
                if let cr = rest.range(of: #"[，,]\s*(有|当|如果|若|要是|一旦|出现|发现|遇到|提醒|通知|请|并|而且|最好|希望)"#, options: .regularExpression) { rest = String(rest[..<cr.lowerBound]) }
                if !rest.trimmingCharacters(in: .whitespaces).isEmpty { return rest }
            }
        }
        return nil
    }

    public static func parse(_ text: String) -> WatchPlan {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let urlStr = url(in: t)
        var plan: WatchPlan
        if let u = urlStr, let repo = githubRepo(u) {
            plan = WatchPlan(type: .githubRelease, title: "\(repo) 新版本")
            plan.targetURL = "https://github.com/\(repo)"
        } else if let u = urlStr {
            let pageWords = ["网页", "页面", "更新日志", "changelog", "变化", "改版", "page"]
            let feedWords = ["rss", "atom", "feed", "博客", "blog", "文章", "订阅"]
            let host = URL(string: u)?.host ?? u
            if feedWords.contains(where: lower.contains) || u.lowercased().contains("rss") || u.lowercased().hasSuffix(".xml") || u.lowercased().contains("feed") {
                plan = WatchPlan(type: .feed, title: "\(host) 新文章")
            } else if pageWords.contains(where: lower.contains) {
                plan = WatchPlan(type: .webpage, title: "\(host) 页面更新")
            } else {
                plan = WatchPlan(type: .feed, title: "\(host) 更新")   // sniffed later; falls back to page
            }
            plan.targetURL = u
        } else {
            plan = WatchPlan(type: .topic, title: topicTitle(t))
        }
        if lower.contains("稳定版") || lower.contains("正式版") || lower.contains("stable") || lower.contains("不要预发布") || lower.contains("不含预发布") || lower.contains("no prerelease") {
            plan.stableOnly = true
        }
        plan.minimumVersion = minimumVersion(in: t)
        plan.minStars = minStars(in: t)
        let unsup = unsupportedConditions(in: t)
        plan.unsupported = unsup.isEmpty ? nil : unsup
        if plan.minimumVersion != nil && plan.type == .githubRelease { plan.stableOnly = plan.stableOnly || lower.contains("版") }
        if let ex = clause(after: ["排除", "不要关注", "不包括", "除去", "除了", "exclude ", "excluding ", "without "], in: t) {
            plan.exclude = splitList(ex).filter { !$0.contains("预发布") }
        }
        if let inc = clause(after: ["尤其是", "特别是", "优先", "重点是", "重点关注", "关键词", "especially ", "focus on ", "keywords:"], in: t) {
            plan.include = splitList(inc.replacingOccurrences(of: "的", with: "").replacingOccurrences(of: "支持", with: "").replacingOccurrences(of: "适合", with: ""))
        }
        if plan.type == .feed || plan.type == .webpage,
           plan.include.isEmpty, let about = clause(after: ["关于", "about "], in: t) {
            plan.include = splitList(about.replacingOccurrences(of: "的新文章", with: "").replacingOccurrences(of: "有", with: "")).filter { $0.count < 24 }
        }
        if plan.type == .topic, plan.include.isEmpty {
            // "关注 ChatGPT、Claude、Codex 的最新动态，包括价格、额度…": the names are the subjects, what follows "包括" is what to watch for
            let (subjects, focus) = subjectsAndFocus(in: t)
            plan.include = subjects
            plan.focus = focus.isEmpty ? nil : focus
            if plan.title == "新关注", !plan.include.isEmpty { plan.title = plan.include.prefix(3).joined(separator: " / ") + " 动态" }
        }
        return plan
    }

    /// The product / company names the watch is about, and the topics it should pay attention to ("包括 / including …").
    static func subjectsAndFocus(in text: String) -> (subjects: [String], focus: [String]) {
        var body = text
        if let r = ["关注", "关于", "follow ", "watch "].compactMap({ body.range(of: $0, options: .caseInsensitive) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            body = String(body[r.upperBound...])
        } else if !(body.first?.isASCII ?? false) { return ([], []) }   // no marker: only a list that starts with a name
        if let end = body.firstIndex(where: { "。.;；\n".contains($0) }) { body = String(body[..<end]) }
        var focusPart = ""
        if let r = body.range(of: #"[，,]?\s*(包括|包含|尤其是|特别是|重点是|including )"#, options: [.regularExpression, .caseInsensitive]) {
            focusPart = String(body[r.upperBound...]); body = String(body[..<r.lowerBound])
        }
        // the descriptive tail ("的最新动态", "等等") is not part of a name
        var cut = body.endIndex
        for m in ["的最新", "最新", "的动态", "动态", "的更新", "的消息", "的信息", "的公告", "等"] { if let r = body.range(of: m), r.lowerBound < cut { cut = r.lowerBound } }
        let subjects = splitList(String(body[..<cut])).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count < 24 && $0.allSatisfy(\.isASCII) }
        let focus = splitList(focusPart.replacingOccurrences(of: "的", with: "")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count < 12 }
        return (subjects, focus)
    }

    static func topicTitle(_ t: String) -> String {
        var s = t
        for p in ["我想持续关注", "我想要关注", "我想关注", "持续关注", "请关注", "关注", "follow ", "watch "] {
            if let r = s.range(of: p, options: [.anchored, .caseInsensitive]) { s = String(s[r.upperBound...]); break }
        }
        if let i = s.firstIndex(where: { "，,。.；;".contains($0) }) { s = String(s[..<i]) }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "新关注" : String(s.prefix(40))
    }

    /// Simple follow-up edits. Returns nil when the sentence can't be reliably interpreted.
    public static func applyEdit(_ text: String, to plan: WatchPlan) -> WatchPlan? {
        var p = plan
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        var changed = false
        if lower.contains("预发布") && (lower.contains("不要") || lower.contains("不含") || lower.contains("排除") || lower.contains("不看")) {
            p.stableOnly = true; changed = true
        } else if lower.contains("包含预发布") || lower.contains("要预发布") || lower.contains("include prerelease") {
            p.stableOnly = false; changed = true
        }
        if let v = minimumVersion(in: t) { p.minimumVersion = v; changed = true }
        if lower.contains("不限版本") || lower.contains("取消版本") { p.minimumVersion = nil; changed = true }
        if let ex = clause(after: ["排除", "不要", "不看", "去掉", "exclude "], in: t), !(lower.contains("预发布") && ex.contains("预发布")) {
            let items = splitList(ex)
            if !items.isEmpty { p.exclude = Array(NSOrderedSet(array: p.exclude + items)) as? [String] ?? p.exclude + items; changed = true }
        }
        if let only = clause(after: ["只关注", "只看", "改成只关注", "改为", "only "], in: t) {
            let items = splitList(only)
            if !items.isEmpty { p.include = items; changed = true }
        } else if let add = clause(after: ["加上", "增加", "也关注", "还要关注", "also "], in: t) {
            let items = splitList(add)
            if !items.isEmpty { p.include = Array(NSOrderedSet(array: p.include + items)) as? [String] ?? p.include + items; changed = true }
        }
        if let n = minStars(in: t) { p.minStars = n; changed = true }
        let u = unsupportedConditions(in: t)
        if !u.isEmpty { p.unsupported = Array(NSOrderedSet(array: (p.unsupported ?? []) + u)) as? [String] ?? u; changed = true }
        return changed ? p : nil
    }
}

public enum Keywords {
    /// A few expansions so Chinese keywords match English repository text.
    static let aliases: [String: [String]] = [
        "ai 绘画": ["stable diffusion", "image generation", "text-to-image", "midjourney", "comfyui", "ai art", "diffusion"],
        "ai绘画": ["stable diffusion", "image generation", "text-to-image", "midjourney", "comfyui", "ai art", "diffusion"],
        "绘画": ["stable diffusion", "image generation", "text-to-image", "ai art", "diffusion"],
        "本地模型": ["local llm", "local model", "locally", "on-device", "on device", "ollama", "gguf", "llama.cpp", "lm studio", "mlx", "offline llm", "self-hosted llm"],
        "本地大模型": ["local llm", "local model", "locally", "on-device", "on device", "ollama", "gguf", "llama.cpp", "lm studio", "mlx", "offline llm", "self-hosted llm"],
        "智能体": ["agent"], "代理": ["agent"],
        "agent": ["agentic", "claude code", "codex", "harness"], "agents": ["agentic", "claude code", "codex", "harness"],
        "mcp": ["model context protocol"],
        "本地部署": ["local llm", "local model", "locally", "on-device", "ollama", "gguf", "llama.cpp", "lm studio", "mlx"], "本地部署模型": ["local llm", "local model", "locally", "on-device", "ollama", "gguf", "llama.cpp", "lm studio", "mlx"],
        "价格": ["pricing", "price"], "额度": ["quota", "usage limit", "credits", "rate limit", "allowance"], "套餐": ["subscription", "pricing plan", "tier"],
    ]
    public static func expand(_ k: String) -> [String] {
        let l = k.lowercased().trimmingCharacters(in: .whitespaces)
        return [l] + (aliases[l] ?? [])
    }
    /// ASCII terms match at a word start ("agent" hits "agents"/"agentic", not "management"); terms of 3 letters or fewer must be whole words.
    /// Hyphens/underscores count as spaces, so the topic "local-llm" matches "local llm".
    public static func matches(_ text: String, any list: [String]) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return list.contains { expand($0).contains { term in
            let term = term.replacingOccurrences(of: "-", with: " ")
            guard term.allSatisfy(\.isASCII) else { return t.contains(term) }
            let pat = "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: term) + (term.count <= 3 ? "(?![a-z0-9])" : "")
            return t.range(of: pat, options: .regularExpression) != nil
        } }
    }
}
