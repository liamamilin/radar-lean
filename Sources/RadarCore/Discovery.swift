import Foundation

public struct Candidate: Identifiable {
    public var id: String { spec.uniqueKey }
    public var spec: SourceSpec
    public var ok: Bool
    public var title: String?
    public var samples: [String]
    public var error: String?
    public var existing: Bool
    public var latest: Date? = nil
    public var matched: Int? = nil   // recent entries mentioning the plan keywords
    public var total = 0
}

public struct Topic {
    public var id: String, name: String, keywords: [String]
    public var candidates: [SourceSpec]
}

public final class Discovery {
    let fetcher: Fetcher
    let store: Store

    /// Starter catalogue: candidates only; every one is probed online before use.
    public static let topics: [Topic] = [
        Topic(id: "ai-open-source", name: "AI 开源项目",
              keywords: ["ai", "llm", "agent", "agents", "gpt", "模型", "人工智能", "智能体", "大模型"],
              candidates: [
                SourceSpec(kind: .githubSearch, endpoint: "topic:ai-agents", name: "GitHub · AI Agent 新项目", interval: 12 * 3600),
                SourceSpec(kind: .githubSearch, endpoint: "topic:local-llm", name: "GitHub · 本地 LLM 新项目", interval: 12 * 3600),
                SourceSpec(kind: .githubSearch, endpoint: "topic:llm", name: "GitHub · LLM 新项目", interval: 12 * 3600),
                SourceSpec(kind: .githubSearch, endpoint: "topic:ollama", name: "GitHub · Ollama 生态新项目", interval: 12 * 3600),
                SourceSpec(kind: .githubSearch, endpoint: "topic:mcp", name: "GitHub · MCP 新项目", interval: 12 * 3600),
              ])
    ]

    public init(fetcher: Fetcher, store: Store) { self.fetcher = fetcher; self.store = store }

    /// Candidate sources for a plan (not yet probed).
    public func specs(for plan: WatchPlan, text: String) async -> [SourceSpec] {
        switch plan.type {
        case .githubRelease:
            guard let u = plan.targetURL, let repo = PlanParser.githubRepo(u) else { return [] }
            return [SourceSpec(kind: .githubReleases, endpoint: repo, name: "\(repo) Releases")]
        case .feed, .webpage:
            guard let u = plan.targetURL else { return [] }
            var out: [SourceSpec] = []
            if let s = try? await fetcher.sniff(u) {
                if s.isFeed { out.append(SourceSpec(kind: .rss, endpoint: u, name: URL(string: u)?.host ?? u)) }
                else {
                    for l in s.feedLinks { out.append(SourceSpec(kind: .rss, endpoint: l, name: (URL(string: l)?.host ?? l) + " Feed")) }
                    if let l = await fetcher.findList(starting: [u]) { out.append(SourceSpec(kind: .list, endpoint: l, name: (URL(string: u)?.host ?? u) + " 列表")) }
                    out.append(SourceSpec(kind: .web, endpoint: u, name: s.title ?? (URL(string: u)?.host ?? u)))
                }
            } else {
                out.append(SourceSpec(kind: .web, endpoint: u, name: URL(string: u)?.host ?? u))
            }
            // honour the requested type: put the preferred kind first
            if plan.type == .webpage { out.sort { $0.kind == .web && $1.kind != .web } }
            return out
        case .topic:
            let l = (text + " " + plan.include.joined(separator: " ") + " " + plan.title).lowercased()
            let tokens = Set(l.split(whereSeparator: { !($0.isLetter || $0.isNumber) || !$0.isASCII }).map(String.init))
            guard let topic = Self.topics.first(where: { t in
                t.keywords.contains { $0.allSatisfy(\.isASCII) ? tokens.contains($0) : l.contains($0) }
            }) else {
                // Unknown topic: offer a plain GitHub keyword search built from the (editable) ASCII keywords; probed before use.
                let kws = plan.include.filter { $0.allSatisfy(\.isASCII) && !$0.isEmpty }
                guard !kws.isEmpty else { return [] }
                let q = kws.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") + " in:name,description,topics"
                return [SourceSpec(kind: .githubSearch, endpoint: q, name: "GitHub · \(kws.joined(separator: " "))", interval: 12 * 3600)]
            }
            let inc = plan.include.joined(separator: " ").lowercased()
            let wantAgent = inc.contains("agent") || inc.contains("智能体")
            let wantLocal = inc.contains("local") || inc.contains("本地")
            let wantMCP = inc.contains("mcp")
            var picks = topic.candidates.filter {
                ($0.endpoint == "topic:ai-agents" && wantAgent) || ($0.endpoint == "topic:local-llm" && wantLocal)
                    || ($0.endpoint == "topic:ollama" && wantLocal) || ($0.endpoint == "topic:mcp" && wantMCP)
            }
            if picks.isEmpty { picks = [topic.candidates.first { $0.endpoint == "topic:llm" }!] }
            return picks
        }
    }

    static let skipHosts = ["github.com", "twitter.com", "x.com", "youtube.com", "facebook.com", "reddit.com", "zhihu.com", "weibo.com", "linkedin.com", "wikipedia.org"]

    /// Web-search the topic, then turn each result site into a feed (preferred) or page source.
    public func searchSpecs(plan: WatchPlan, text: String) async -> [SourceSpec] {
        let kws = plan.include.filter { !$0.isEmpty }
        let q = (kws.isEmpty ? plan.title : kws.joined(separator: " ")) + " 最新 资讯 博客 blog news"
        guard let results = try? await fetcher.webSearch(q) else { return [] }
        var seen = Set<String>(), picks: [String] = []
        for r in results {
            guard let h = URL(string: r.url)?.host?.lowercased(), !Self.skipHosts.contains(where: { h == $0 || h.hasSuffix("." + $0) }),
                  seen.insert(h).inserted else { continue }
            picks.append(r.url)
            if picks.count == 8 { break }
        }
        let fetcher = self.fetcher
        let found: [(Int, SourceSpec)] = await withTaskGroup(of: (Int, SourceSpec)?.self) { g in
            for (i, u) in picks.enumerated() {
                g.addTask {
                    let host = URL(string: u)?.host ?? u
                    var tries = [u]
                    if let sc = URL(string: u)?.scheme { tries.append("\(sc)://\(host)/") }
                    for t in tries {
                        guard let s = try? await fetcher.sniff(t) else { continue }
                        if s.isFeed { return (i, SourceSpec(kind: .rss, endpoint: t, name: host)) }
                        if let l = s.feedLinks.first { return (i, SourceSpec(kind: .rss, endpoint: l, name: host + " Feed")) }
                    }
                    // no feed: a listing page we can read item by item
                    if let l = await fetcher.findList(starting: tries.reversed()) { return (i, SourceSpec(kind: .list, endpoint: l, name: host + " 列表")) }
                    return nil
                }
            }
            var all: [(Int, SourceSpec)] = []
            for await x in g { if let x { all.append(x) } }
            return all
        }
        return found.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    public func probe(_ spec: SourceSpec, include: [String] = []) async -> Candidate {
        let existing = (try? await store.db.read { try Source.filter(Column("uniqueKey") == spec.uniqueKey).fetchCount($0) })?.advanced(by: 0) ?? 0
        do {
            let r = spec.kind == .githubSearch ? try await fetcher.sampleSearch(spec.endpoint) : try await fetcher.fetch(spec)
            if r.entries.isEmpty && spec.kind != .githubReleases { throw RadarError.parse("没有读到任何内容") }
            let hits = include.isEmpty ? nil : r.entries.filter { Keywords.matches($0.title + " " + $0.summary, any: include) }.count
            return Candidate(spec: spec, ok: true, title: r.title, samples: spec.kind == .web ? [String(r.entries[0].summary.prefix(240))] : r.entries.prefix(4).map { $0.title }, error: nil, existing: existing > 0,
                             latest: r.entries.compactMap { $0.publishedAt }.max(), matched: hits, total: r.entries.count)
        } catch {
            return Candidate(spec: spec, ok: false, title: nil, samples: [], error: error.localizedDescription, existing: existing > 0)
        }
    }

    /// The topic changed: attach good new sources (no backfill), and report attached ones that no longer fit the keywords.
    public func rediscover(watchID: Int64, plan: WatchPlan, text: String) async -> (added: [Candidate], stale: [String], errors: [String]) {
        let current = (try? await store.db.read { try Source.fetchAll($0, sql: "SELECT source.* FROM source JOIN watchSource ws ON ws.sourceID = source.id WHERE ws.watchID = ?", arguments: [watchID]) }) ?? []
        let have = Set(current.map { $0.uniqueKey })
        let cands = await findSources(plan: plan, text: text + " " + plan.include.joined(separator: " "))
        let fresh = Array(cands.filter { $0.ok && !have.contains($0.spec.uniqueKey) && ($0.matched ?? 1) > 0 }.prefix(3))
        for c in fresh { _ = try? store.attach(watchID: watchID, spec: c.spec) }
        var stale: [String] = []
        for s in current where s.kind == .rss || s.kind == .list {
            let c = await probe(SourceSpec(kind: s.kind, endpoint: s.endpoint, name: s.name), include: plan.include)
            if c.ok, c.total > 0, c.matched == 0 { stale.append(s.name) }
        }
        return (fresh, stale, cands.filter { !$0.ok && !have.contains($0.spec.uniqueKey) }.compactMap { $0.error }.prefix(2).map { $0 })
    }

    public func findSources(plan: WatchPlan, text: String) async -> [Candidate] {
        // probe in parallel (keeps order); a slow site no longer holds up the others
        func probeAll(_ list: [SourceSpec], include: [String]) async -> [Candidate] {
            await withTaskGroup(of: (Int, Candidate).self) { g in
                for (i, s) in list.enumerated() { g.addTask { (i, await self.probe(s, include: include)) } }
                var r: [(Int, Candidate)] = []
                for await x in g { r.append(x) }
                return r.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        }
        async let webSpecs: [SourceSpec] = plan.type == .topic ? searchSpecs(plan: plan, text: text) : []   // overlaps with the GitHub probes
        var out = await probeAll(await specs(for: plan, text: text), include: [])
        guard plan.type == .topic else { return out }
        // Web-searched sites: probe, drop dead/stale feeds, rank by keyword hits then freshness.
        let searched = await webSpecs.filter { s in !out.contains(where: { $0.spec.uniqueKey == s.uniqueKey }) }
        var found: [Candidate] = await probeAll(searched, include: plan.include)
        found.removeAll { c in if c.ok, let l = c.latest, l < Date().addingTimeInterval(-365 * 86400) { return true }; return false }
        found.sort { ($0.matched ?? 0, $0.latest ?? .distantPast) > ($1.matched ?? 0, $1.latest ?? .distantPast) }
        out += found
        return out
    }
}

import GRDB
