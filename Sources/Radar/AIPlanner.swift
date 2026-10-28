import Foundation
import FoundationModels
import RadarCore

@available(macOS 26.0, *)
@Generable
struct PlanDraft {
    @Guide(description: "A short title for what the user wants to follow, in the user's language")
    var title: String
    @Guide(description: "Keywords the content should mention; empty if none requested")
    var include: [String]
    @Guide(description: "Keywords that must NOT appear; empty if none requested")
    var exclude: [String]
    @Guide(description: "True only if the user wants stable/official releases without prereleases")
    var stableOnly: Bool
    @Guide(description: "Minimum version like 1.0.0, or empty string if none")
    var minimumVersion: String
}

/// Optional enhancement: on-device model refines the deterministic plan. Never required.
enum AIPlanner {
    static var available: Bool {
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func refine(_ base: WatchPlan, text: String, followUp: Bool = false) async -> WatchPlan? {
        guard #available(macOS 26.0, *) else { return nil }
        return await refine26(base, text: text, followUp: followUp)
    }

    /// Takes the rule-based plan as a base and overrides fields the model filled in.
    @available(macOS 26.0, *)
    static func refine26(_ base: WatchPlan, text: String, followUp: Bool) async -> WatchPlan? {
        guard available else { return nil }
        let session = LanguageModelSession(instructions: """
            Extract a monitoring plan from the user's request. Only use what the user actually said; \
            do not invent keywords. Current plan: include=\(base.include), exclude=\(base.exclude), \
            stableOnly=\(base.stableOnly), minimumVersion=\(base.minimumVersion ?? ""). \
            \(followUp ? "The request is an edit to the current plan; return the full updated plan." : "")
            """)
        guard let r = try? await session.respond(to: text, generating: PlanDraft.self).content else { return nil }
        var p = base
        if !r.title.isEmpty && !followUp { p.title = r.title }
        p.include = r.include.filter { !$0.isEmpty }
        p.exclude = r.exclude.filter { !$0.isEmpty }
        p.stableOnly = r.stableOnly || (followUp && base.stableOnly && !text.contains("预发布"))
        p.minimumVersion = r.minimumVersion.isEmpty ? base.minimumVersion : r.minimumVersion
        return p
    }
}
