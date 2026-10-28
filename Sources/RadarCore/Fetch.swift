import Foundation
import SwiftSoup
import FeedKit

public struct FetchedEntry {
    public var externalKey: String
    public var url: String
    public var title: String
    public var summary: String = ""
    public var text: String = ""
    public var publishedAt: Date?
    public var meta: [String: String] = [:]
    public var contentHash: String { sha256(text.isEmpty ? title + "\n" + summary : text) }
}

public struct FetchResult {
    public var entries: [FetchedEntry]
    public var notModified = false
    public var etag: String?
    public var lastModified: String?
    public var title: String?
}

public enum RadarError: LocalizedError {
    case http(Int, String)
    case rateLimited(until: Date)
    case unsupported(String)
    case parse(String)
    public var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "HTTP \(c)\(m.isEmpty ? "" : "：" + m)"
        case .rateLimited(let d): return "被限流，\(d.formatted(date: .omitted, time: .shortened)) 后重试"
        case .unsupported(let m), .parse(let m): return m
        }
    }
}

/// Spaces out GitHub search calls (10/min without a token, 30/min with one) so a burst never trips the limit.
actor Throttle {
    var next = Date.distantPast
    func wait(_ gap: TimeInterval) async {
        let now = Date(), at = max(now, next)
        next = at.addingTimeInterval(gap)
        if at > now { try? await Task.sleep(nanoseconds: UInt64(at.timeIntervalSince(now) * 1e9)) }
    }
}

public final class Fetcher {
    let searchGate = Throttle()
    public var searchGap: TimeInterval?    // nil = by GitHub's limits; tests set 0
    public var session: URLSession
    public var githubToken: () -> String?
    public var searchKey: () -> String?
    public var searchEndpoint = "https://api.exa.ai/search"
    public var githubBase = "https://api.github.com"   // overridable for local end-to-end runs

    public init(session: URLSession? = nil, githubToken: @escaping () -> String? = { nil }, searchKey: @escaping () -> String? = { nil }) {
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 40
            self.session = URLSession(configuration: cfg)
        }
        self.githubToken = githubToken
        self.searchKey = searchKey
    }

    struct Response { var data: Data; var status: Int; var headers: [String: String]; var url: URL }

    func get(_ url: URL, headers: [String: String] = [:], maxBytes: Int = 5_000_000) async throws -> Response {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw RadarError.unsupported("仅支持 http(s) 地址") }
        var req = URLRequest(url: url)
        req.setValue("Radar/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RadarError.http(0, "无响应") }
        var h: [String: String] = [:]
        for (k, v) in http.allHeaderFields { h["\(k)".lowercased()] = "\(v)" }
        guard data.count <= maxBytes else { throw RadarError.unsupported("内容过大") }
        return Response(data: data, status: http.statusCode, headers: h, url: http.url ?? url)
    }

    func check(_ r: Response, allow304: Bool) throws {
        if r.status == 304 && allow304 { return }
        if r.status == 429 || (r.status == 403 && (r.headers["x-ratelimit-remaining"] == "0" || r.headers["retry-after"] != nil)) {
            var until = Date().addingTimeInterval(15 * 60)
            if let ra = r.headers["retry-after"], let s = Double(ra) { until = Date().addingTimeInterval(s) }
            else if let reset = r.headers["x-ratelimit-reset"], let t = Double(reset) { until = Date(timeIntervalSince1970: t) }
            throw RadarError.rateLimited(until: until)
        }
        guard (200..<300).contains(r.status) else {
            var msg = ""
            if let o = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any], let m = o["message"] as? String { msg = m }
            throw RadarError.http(r.status, msg)
        }
    }

    func githubHeaders() -> [String: String] {
        var h = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        if let t = githubToken(), !t.isEmpty { h["Authorization"] = "Bearer \(t)" }
        return h
    }

    public func fetch(_ src: SourceSpec, etag: String? = nil, lastModified: String? = nil) async throws -> FetchResult {
        var cond: [String: String] = [:]
        if let etag { cond["If-None-Match"] = etag }
        if let lastModified { cond["If-Modified-Since"] = lastModified }
        switch src.kind {
        case .githubReleases: return try await fetchReleases(src.endpoint, cond: cond)
        case .githubSearch: return try await fetchSearch(src.endpoint, cond: cond)
        case .rss: return try await fetchFeed(src.endpoint, cond: cond)
        case .web: return try await fetchPage(src.endpoint, selector: src.selector, cond: cond)
        case .list: return try await fetchList(src.endpoint, cond: cond)
        }
    }

    // MARK: GitHub

    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); return f }()

    func fetchReleases(_ repo: String, cond: [String: String]) async throws -> FetchResult {
        let url = URL(string: "\(githubBase)/repos/\(repo)/releases?per_page=30")!
        let r = try await get(url, headers: githubHeaders().merging(cond) { $1 })
        if r.status == 304 { return FetchResult(entries: [], notModified: true, etag: cond["If-None-Match"], lastModified: cond["If-Modified-Since"]) }
        try check(r, allow304: true)
        guard let arr = try JSONSerialization.jsonObject(with: r.data) as? [[String: Any]] else { throw RadarError.parse("Releases 响应格式不符") }
        let entries: [FetchedEntry] = arr.compactMap { o in
            guard let id = o["id"] as? Int, let tag = o["tag_name"] as? String else { return nil }
            let html = o["html_url"] as? String ?? "https://github.com/\(repo)/releases/tag/\(tag)"
            let body = o["body"] as? String ?? ""
            var e = FetchedEntry(externalKey: "\(id)", url: html,
                                 title: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
                                 summary: String(body.prefix(500)), text: tag + "\n" + body)
            e.publishedAt = (o["published_at"] as? String).flatMap { Self.iso.date(from: $0) }
            e.meta = ["tag": tag, "prerelease": (o["prerelease"] as? Bool ?? false) ? "1" : "0", "draft": (o["draft"] as? Bool ?? false) ? "1" : "0"]
            return e
        }
        return FetchResult(entries: entries, etag: r.headers["etag"], title: repo)
    }

    /// Three star bands over recent creation dates, merged: fresh risers (14 days, 5+ stars), the middle band (90 days, 30–400 stars)
    /// and the top band (90 days, 400+). One ranking by stars would be filled by mega-projects and hide everything in the middle.
    func fetchSearch(_ query: String, cond: [String: String]) async throws -> FetchResult {
        var seen = Set<Int>(), entries: [FetchedEntry] = []
        for (days, stars) in [(14, ">=5"), (90, "30..400"), (90, ">400")] {
            for e in try await searchRepos(query, days: days, stars: stars, perPage: 100) where seen.insert(Int(e.externalKey) ?? 0).inserted {
                entries.append(e)
            }
        }
        return FetchResult(entries: entries, title: query)
    }

    /// One cheap query, enough to tell a candidate source works and show samples.
    public func sampleSearch(_ query: String) async throws -> FetchResult {
        FetchResult(entries: try await searchRepos(query, days: 90, stars: "30..400", perPage: 20), title: query)
    }

    func searchRepos(_ query: String, days: Int, stars: String, perPage: Int) async throws -> [FetchedEntry] {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone(identifier: "UTC")
        let since = df.string(from: Date().addingTimeInterval(-Double(days) * 86400))
        var c = URLComponents(string: "\(githubBase)/search/repositories")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(query) created:>=\(since) stars:\(stars) fork:false archived:false"),
                        URLQueryItem(name: "sort", value: "stars"), URLQueryItem(name: "order", value: "desc"),
                        URLQueryItem(name: "per_page", value: String(perPage))]
        if githubBase == "https://api.github.com" {
            await searchGate.wait(searchGap ?? ((githubToken() ?? "").isEmpty ? 6.5 : 2.1))
        }
        let r = try await get(c.url!, headers: githubHeaders(), maxBytes: 8_000_000)   // no conditional: query window moves daily
        try check(r, allow304: false)
        guard let o = try JSONSerialization.jsonObject(with: r.data) as? [String: Any], let items = o["items"] as? [[String: Any]]
        else { throw RadarError.parse("搜索响应格式不符") }
        return items.compactMap { i in
            guard let id = i["id"] as? Int, let name = i["full_name"] as? String, let url = i["html_url"] as? String else { return nil }
            if i["fork"] as? Bool == true || i["archived"] as? Bool == true { return nil }
            let desc = i["description"] as? String ?? ""
            let topics = (i["topics"] as? [String]) ?? []
            var e = FetchedEntry(externalKey: "\(id)", url: url, title: name, summary: desc,
                                 text: name + "\n" + desc + "\n" + topics.joined(separator: " "))
            e.publishedAt = (i["created_at"] as? String).flatMap { Self.iso.date(from: $0) }
            e.meta = ["stars": "\(i["stargazers_count"] as? Int ?? 0)", "forks": "\(i["forks_count"] as? Int ?? 0)",
                      "language": i["language"] as? String ?? "", "fullName": name, "topics": topics.joined(separator: ","),
                      "pushed": i["pushed_at"] as? String ?? ""]
            return e
        }
    }

    // MARK: RSS / Atom

    func fetchFeed(_ urlString: String, cond: [String: String]) async throws -> FetchResult {
        guard let url = URL(string: urlString) else { throw RadarError.parse("无效地址") }
        let r = try await get(url, headers: cond)
        if r.status == 304 { return FetchResult(entries: [], notModified: true, etag: cond["If-None-Match"], lastModified: cond["If-Modified-Since"]) }
        try check(r, allow304: true)
        var res = try parseFeed(r.data, base: url)
        res.etag = r.headers["etag"]; res.lastModified = r.headers["last-modified"]
        return res
    }

    func parseFeed(_ data: Data, base: URL) throws -> FetchResult {
        guard case .success(let feed) = FeedParser(data: data).parse() else { throw RadarError.parse("不是有效的 RSS/Atom 内容") }
        var title: String?
        var entries: [FetchedEntry] = []
        func add(id: String?, link: String?, title t: String?, summary: String?, date: Date?) {
            let linkURL = link.flatMap { URL(string: $0, relativeTo: base)?.absoluteString } ?? ""
            let key = (id?.isEmpty == false ? id! : linkURL)
            guard !key.isEmpty else { return }
            let clean = (try? SwiftSoup.parse(summary ?? "").text()) ?? summary ?? ""
            var e = FetchedEntry(externalKey: key, url: linkURL.isEmpty ? base.absoluteString : linkURL,
                                 title: (t ?? linkURL).trimmingCharacters(in: .whitespacesAndNewlines), summary: String(clean.prefix(500)))
            e.publishedAt = date
            entries.append(e)
        }
        switch feed {
        case .rss(let f):
            title = f.title
            for i in f.items ?? [] {
                add(id: i.guid?.value, link: i.link, title: i.title, summary: i.description, date: i.pubDate)
            }
        case .atom(let f):
            title = f.title
            for i in f.entries ?? [] {
                let href = i.links?.first(where: { $0.attributes?.rel == nil || $0.attributes?.rel == "alternate" })?.attributes?.href
                add(id: i.id, link: href, title: i.title, summary: i.summary?.value ?? i.content?.value, date: i.published ?? i.updated)
            }
        case .json(let f):
            title = f.title
            for i in f.items ?? [] { add(id: i.id, link: i.url, title: i.title, summary: i.summary ?? i.contentText, date: i.datePublished) }
        }
        return FetchResult(entries: entries, title: title)
    }

    // MARK: HTML

    func fetchPage(_ urlString: String, selector: String?, cond: [String: String]) async throws -> FetchResult {
        guard let url = URL(string: urlString) else { throw RadarError.parse("无效地址") }
        let r = try await get(url, headers: cond)
        if r.status == 304 { return FetchResult(entries: [], notModified: true, etag: cond["If-None-Match"], lastModified: cond["If-Modified-Since"]) }
        try check(r, allow304: true)
        var res = try extractPage(html: String(decoding: r.data, as: UTF8.self), url: r.url, selector: selector)
        res.etag = r.headers["etag"]; res.lastModified = r.headers["last-modified"]
        return res
    }

    public func extractPage(html: String, url: URL, selector: String?) throws -> FetchResult {
        let doc = try SwiftSoup.parse(html, url.absoluteString)
        let title = (try? doc.title()) ?? ""
        try doc.select("script, style, noscript, nav, footer, header, template, svg").remove()
        var root: Element?
        if let selector, !selector.isEmpty { root = try doc.select(selector).first() }
        else { for s in ["article", "main", "[role=main]", "body"] { if let e = try doc.select(s).first() { root = e; break } } }
        guard let root else { throw RadarError.parse("没有匹配选择器的正文区域") }
        let text = try root.text().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard text.count >= 20 else { throw RadarError.unsupported("没有提取到静态正文（可能是 JavaScript 动态页面），暂不支持") }
        var e = FetchedEntry(externalKey: "page", url: url.absoluteString, title: title.isEmpty ? url.host ?? "网页" : title,
                             summary: String(text.prefix(300)), text: text)
        e.meta = [:]
        return FetchResult(entries: [e], title: title)
    }

    // MARK: Article / project list pages (no RSS)

    func fetchList(_ urlString: String, cond: [String: String]) async throws -> FetchResult {
        guard let url = URL(string: urlString) else { throw RadarError.parse("无效地址") }
        let r = try await get(url, headers: cond)
        if r.status == 304 { return FetchResult(entries: [], notModified: true, etag: cond["If-None-Match"], lastModified: cond["If-Modified-Since"]) }
        try check(r, allow304: true)
        var res = try extractList(html: String(decoding: r.data, as: UTF8.self), url: r.url)
        res.etag = r.headers["etag"]; res.lastModified = r.headers["last-modified"]
        return res
    }

    static let skipPath = ["/tag", "/tags", "/category", "/categories", "/author", "/page", "/about", "/contact", "/privacy", "/login", "/signin", "/search", "/terms"]
    static let genericText: Set<String> = ["read more", "learn more", "more", "阅读更多", "查看更多", "了解更多", "下一页", "上一页", "next", "previous", "home", "首页"]

    /// Pull independent items (title, link, blurb, date) out of a static listing page: the biggest group of
    /// same-structure links wins; fewer than 5 means it is an article, not a list.
    public func extractList(html: String, url: URL) throws -> FetchResult {
        let doc = try SwiftSoup.parse(html, url.absoluteString)
        try doc.select("script, style, noscript, nav, footer, aside, template, svg, body > header").remove()
        func host(_ u: URL?) -> String { (u?.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "") }
        let pageHost = host(url)
        var groups: [String: [(Element, URL, String)]] = [:]
        for a in try doc.select("a[href]").array() {
            guard let u = URL(string: (try? a.absUrl("href")) ?? ""), ["http", "https"].contains(u.scheme ?? "") else { continue }
            let h = host(u)
            guard h == pageHost || h == "github.com" else { continue }
            let path = u.path.lowercased()
            if path.count < 2 || normalizeURL(u.absoluteString) == normalizeURL(url.absoluteString) { continue }
            if Self.skipPath.contains(where: { path.hasPrefix($0) }) { continue }
            var title = ((try? a.select("h1,h2,h3,h4").first()?.text()) ?? nil) ?? ((try? a.text()) ?? "")
            title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let cjk = title.unicodeScalars.contains { $0.value > 0x2E80 }
            // "Read analysis"-style call-to-action links: take the card's single heading instead
            if let box = Self.card(a, title), let hs = try? box.select("h1,h2,h3,h4"), hs.count == 1, ((try? box.select("a[href]").count) ?? 9) <= 4,
               (try? a.select("h1,h2,h3,h4").first()) == nil, let ht = try? hs.first()?.text(), ht.count >= 8 {
                title = ht.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
            let low = title.lowercased()
            guard title.count >= (cjk ? 6 : 12), title.count <= 200, !Self.genericText.contains(low),
                  !(low.hasPrefix("read ") && title.count < 24), !low.hasPrefix("continue reading") else { continue }
            let p = a.parent(), g = p?.parent()
            let sig = [p?.tagName(), (try? p?.className()).flatMap { $0 }.map { String($0.split(separator: " ").first ?? "") }, g?.tagName()].compactMap { $0 }.joined(separator: "/")
            groups[sig, default: []].append((a, u, title))
        }
        func size(_ g: [(Element, URL, String)]) -> Int { Set(g.map { normalizeURL($0.1.absoluteString) }).count }
        guard let best = groups.values.max(by: { size($0) < size($1) }) else {
            throw RadarError.unsupported("没有识别出文章/项目列表")
        }
        var seen = Set<String>(), entries: [FetchedEntry] = []
        for (a, u, title) in best where seen.insert(normalizeURL(u.absoluteString)).inserted {
            let box = Self.card(a, title)
            var blurb = (try? box?.text()) ?? ""
            blurb = blurb.replacingOccurrences(of: title, with: "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            var e = FetchedEntry(externalKey: normalizeURL(u.absoluteString), url: u.absoluteString, title: title, summary: String(blurb.prefix(240)))
            if let t = try? box?.select("time[datetime]").first()?.attr("datetime") { e.publishedAt = Self.iso.date(from: t) ?? Self.day(t) }
            else if let m = blurb.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) { e.publishedAt = Self.day(String(blurb[m])) }
            entries.append(e)
            if entries.count == 60 { break }
        }
        guard entries.count >= 5 else { throw RadarError.unsupported("没有识别出文章/项目列表（只找到 \(entries.count) 条）") }
        return FetchResult(entries: entries, title: (try? doc.title()).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The small enclosing block that holds a link's title and blurb (grow until it has some text beyond the title).
    static func card(_ a: Element, _ title: String) -> Element? {
        var box: Element? = a.parent()
        for _ in 0..<3 { if let b = box, ((try? b.text().count) ?? 0) > title.count + 30 { break } else { box = box?.parent() } }
        return box
    }

    static func day(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    /// First page among a few likely ones (site root, the given URL, then /blog /news … links) that reads as a list.
    public func findList(starting: [String]) async -> String? {
        var queue = starting, seen = Set<String>(), tries = 0
        while tries < 3, !queue.isEmpty {
            let u = queue.removeFirst()
            guard seen.insert(normalizeURL(u)).inserted, let url = URL(string: u) else { continue }
            tries += 1
            guard let r = try? await get(url), (200..<300).contains(r.status) else { continue }
            let html = String(decoding: r.data, as: UTF8.self)
            if (try? extractList(html: html, url: r.url)) != nil { return r.url.absoluteString }
            for a in ((try? SwiftSoup.parse(html, r.url.absoluteString).select("a[href]").array()) ?? []) {
                guard let hu = URL(string: (try? a.absUrl("href")) ?? ""), hu.host == r.url.host, hu.pathComponents.count <= 2 else { continue }
                if ["/blog", "/news", "/articles", "/posts", "/changelog", "/releases", "/updates"].contains(where: { hu.path.lowercased().hasPrefix($0) }) { queue.append(hu.absoluteString) }
            }
        }
        return nil
    }

    /// Exa web search results (title, url). Empty when no API key is configured.
    public func webSearch(_ query: String, count: Int = 15) async throws -> [(title: String, url: String)] {
        guard let key = searchKey(), !key.isEmpty else { return [] }
        var req = URLRequest(url: URL(string: searchEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "numResults": count, "type": "auto",
                                                                  "startPublishedDate": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-180 * 86400))])
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RadarError.http(status, "Exa 搜索失败") }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = o["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { x in
            guard let u = x["url"] as? String else { return nil }
            return ((x["title"] as? String) ?? u, u)
        }
    }

    /// Fetch a page and return (looksLikeFeed, feedURLs, title).
    public func sniff(_ urlString: String) async throws -> (isFeed: Bool, feedLinks: [String], title: String?) {
        guard let url = URL(string: urlString) else { throw RadarError.parse("无效地址") }
        let r = try await get(url)
        try check(r, allow304: false)
        let head = String(decoding: r.data.prefix(2000), as: UTF8.self).lowercased()
        if head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf") {
            return (true, [], nil)
        }
        let doc = try SwiftSoup.parse(String(decoding: r.data, as: UTF8.self), r.url.absoluteString)
        let links = try doc.select("link[rel=alternate]").array().compactMap { l -> String? in
            let t = (try? l.attr("type"))?.lowercased() ?? ""
            guard t.contains("rss") || t.contains("atom") else { return nil }
            return try? l.absUrl("href")
        }.filter { !$0.isEmpty }
        return (false, Array(NSOrderedSet(array: links)) as? [String] ?? links, try? doc.title())
    }
}
