import Foundation

/// "Why didn't Radar tell me about this?" Given a link the user saw elsewhere, checks each step the link would have had to pass
/// and says which one failed. Read-only: nothing is stored or changed.
public struct MissDiagnosis {
    public struct Finding { public var ok: Bool; public var text: String }
    public var findings: [Finding] = []
    public var suggestion: SourceSpec?       // an official channel that would cover this link, if the catalog knows one

    public static func diagnose(url: String, plan: WatchPlan, sources: [Source], entries: [Entry], fetcher: Fetcher) async -> MissDiagnosis {
        var d = MissDiagnosis()
        func add(_ ok: Bool, _ t: String) { d.findings.append(Finding(ok: ok, text: t)) }
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), let host = u.host?.lowercased() else {
            add(false, "这不是一个有效的网址"); return d
        }
        func bare(_ h: String) -> String { h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        let key = mergeKey(u.absoluteString)

        // 1. did Radar read this link at all?
        let seen = entries.first { mergeKey($0.canonicalURL) == key }
        // 2. which sources live on the same site?
        let sameSite = sources.filter { s in
            guard s.kind != .githubSearch, s.kind != .hackerNews, let h = URL(string: s.endpoint)?.host?.lowercased() else { return false }
            return bare(h) == bare(host) || bare(h).hasSuffix("." + bare(host)) || bare(host).hasSuffix("." + bare(h))
        }
        if let seen {
            add(true, "Radar 已经读到了它（\(seen.firstSeenAt.formatted(date: .abbreviated, time: .shortened))）：\(seen.title)")
            let kind = sources.first { $0.id == seen.sourceID }?.kind ?? .rss
            let isNew = Engine.evaluate(plan: plan, kind: kind == .githubReleases || kind == .githubSearch || kind == .web ? .rss : kind, entry: seen, change: .new)
            if let j = isNew {
                if Engine.shouldNotify(plan: plan, kind: j.kind) { add(true, "按现在的规则会产生事件并通知（\(j.reason)）。如果当时没提醒，可能是读到它时规则还不一样。") }
                else { add(false, "读到了，但只被归为“\(j.kind == "update" ? "普通更新" : j.kind)”，这个关注只通知新项目 / 重大更新。可以在条件里放宽，或加关键词。") }
            } else {
                add(false, "读到了，但被这个关注的关键词过滤掉了（标题和摘要没有命中“包含”词，或命中了“排除”词）。")
            }
            return d
        }
        add(false, "Radar 没有读到过这个链接")
        if sameSite.isEmpty {
            add(false, "没有任何来源覆盖 \(host)——这是来源缺口，不是规则问题。")
            d.suggestion = OfficialCatalog.entities.flatMap { $0.channels }.first { c in
                guard let h = URL(string: c.spec.endpoint)?.host?.lowercased() else { return false }
                return bare(h) == bare(host) && c.auto
            }?.spec
            if let s = d.suggestion { add(false, "官方目录里有可用渠道：\(s.name)。") }
        } else {
            for s in sameSite {
                if let e = s.lastError { add(false, "来源“\(s.name)”最近一次读取失败：\(e)") }
                else if !s.initialized { add(false, "来源“\(s.name)”还没完成首次读取") }
                else { add(true, "来源“\(s.name)”能正常读取，但没有出现这个链接——它可能不在该来源的列表里（例如在别的栏目或二级页面）。") }
            }
        }

        // 3. can Radar read the page itself?
        do {
            let r = try await fetcher.fetch(SourceSpec(kind: .web, endpoint: u.absoluteString, name: "diagnose"))
            if let t = r.entries.first?.title, !t.isEmpty { add(true, "页面本身能读到：\(t)") } else { add(true, "页面本身能读到") }
        } catch {
            add(false, "Radar 读不到这个页面：\(error.localizedDescription)。需要 JavaScript 的页面可以用 js: 选择器；被拦截的页面 Radar 不会绕过。")
        }
        return d
    }
}
