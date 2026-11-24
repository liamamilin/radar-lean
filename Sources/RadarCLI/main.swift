import Foundation
import RadarCore

// radar-cli — prints the AI briefings Radar has saved, for other programs to reuse. Read-only: never touches the app's data.

let usage = """
用法: radar-cli briefing [--day today|latest|yyyy-MM-dd] [--format json|markdown] [--db <radar.sqlite>]
      radar-cli days [--db <radar.sqlite>]

  briefing   输出某天的 AI 简报（默认 latest = 最近一份）。找不到时退出码为 2。
  days       列出已有简报的日期（每行一个，新的在前）。
  --format   json（默认）或 markdown。
  --db       数据库路径，默认 ~/Library/Application Support/Radar/radar.sqlite。
"""

func fail(_ msg: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, command != "-h", command != "--help", command != "help" else { print(usage); exit(args.isEmpty ? 1 : 0) }
args.removeFirst()

var day = "latest", format = "json", dbPath: String?
var i = 0
while i < args.count {
    let a = args[i]
    guard ["--day", "--format", "--db"].contains(a), i + 1 < args.count else { fail("无法识别的参数: \(a)\n\n\(usage)", code: 1) }
    let v = args[i + 1]
    switch a { case "--day": day = v; case "--format": format = v; default: dbPath = v }
    i += 2
}
guard ["json", "markdown"].contains(format) else { fail("--format 只支持 json 或 markdown", code: 1) }

func markdown(_ b: Briefing) -> String {
    var out = "# Radar 简报 \(b.day)\n\n"
    if b.hasOverview { out += b.overview + "\n\n" }
    for s in b.activeSections {
        out += "## \(s.title)\n\n\(s.text)\n\n"
        for e in s.evidence { out += "- [\(e.id)] [\(e.title)](\(e.url))" + (e.origin.isEmpty ? "" : " · \(e.origin)") + "\n" }
        out += "\n"
    }
    return out
}

do {
    let path = try dbPath ?? Store.defaultPath()
    guard FileManager.default.fileExists(atPath: path) else { fail("找不到数据库: \(path)", code: 2) }
    let all = try Briefer.readOnlyDays(path: path)
    switch command {
    case "days":
        all.forEach { print($0.day) }
    case "briefing":
        let key = day == "today" ? Briefer.dayKey(Date()) : day
        guard let b = key == "latest" ? all.first : all.first(where: { $0.day == key }) else { fail("没有 \(day) 的简报", code: 2) }
        if format == "markdown" { print(markdown(b)) } else {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try e.encode(b), as: UTF8.self))
        }
    default: fail("未知命令: \(command)\n\n\(usage)", code: 1)
    }
} catch {
    fail("读取失败: \(error.localizedDescription)", code: 3)
}
