import Foundation

/// Ordered checkpoints owned by the harness, not a plan the actor can silently restart.
struct ExecutionPlan {
    struct Checkpoint: Codable, Equatable {
        let goal: String
        let verify: String
        let group: String
        var status = "pending"
        var evidence = ""
    }
    private(set) var checkpoints: [Checkpoint] = []
    var currentIndex: Int? { checkpoints.firstIndex { $0.status == "pending" } }
    var complete: Bool { !checkpoints.isEmpty && currentIndex == nil }
    var current: Checkpoint? { currentIndex.map { checkpoints[$0] } }

    static let planningRules = """
    Build an execution plan with observable checkpoints, not a vague list of intentions.
    Reply ONLY with JSON: {"steps":[{"goal":"...","verify":"visible evidence required","group":"..."}]}.
    Use 1–12 steps, each goal/verify at most 400 characters and group at most 64 characters.
    Include EVERY app/source requested by the user, in order. Preserve the supplied destination exactly;
    never silently choose a different location. Ask for help if location identity cannot be established.
    For a ride-price comparison, give each requested provider three checkpoints in its own group:
    (1) search for and open that app; verify its actual app screen,
    (2) enter the user's destination, select the matching result, verify pickup and destination,
    (3) collect the requested ride option's fare/currency, wait and conditions; store it before leaving.
    Finish with a separate comparison checkpoint using the collected results. If a source is unavailable,
    record why and continue other sources. Only inspect quotes: never book, request, confirm or pay for rides.
    For other tasks, split at meaningful screen/result boundaries. Use a shared nonempty group only for
    dependent steps that should ALL be skipped if that group is unavailable; independent steps need different groups.
    Do not make coordinates part of the plan. The actor must locate controls on each current screenshot.
    """

    static let actingRules = """
    Follow the harness's ACTIVE CHECKPOINT only. Completed checkpoints stay completed across replanning.
    First inspect the screen. Once the active checkpoint's verification condition is visibly satisfied,
    save relevant MEMORY facts and emit ONE action: DO checkpoint <specific observed evidence>.
    This records progress without touching the phone. The harness then selects the next checkpoint.
    If the app/source is unavailable or needs login/user input, use DO blocked <observed reason>;
    this marks the active checkpoint and later dependent steps in its group unavailable, then continues.
    Never claim completion from a tap alone. Do not search again for an app already open. Search for an app
    using Home, then the visible Search field (or a downward swipe); type its name ONLY in a focused field,
    then open the matching result. Wait for loading instead of immediately going Home again.
    For destination entry, focus the field, replace old text, select the matching result and verify the route.
    Never silently substitute an ambiguous destination. Stop for help if clarification is required.
    For ride quotes, never book, request, reserve, confirm or pay. A quote is enough.
    Emit only ONE DO action per reply while executing checkpoints. Use DO replan to repair the current
    checkpoint; it cannot restart completed work. DO done is allowed only after all checkpoints have outcomes,
    or to complete the final checkpoint with an evidence-based final answer.
    Final answers must distinguish missing/blocked results from verified results; do not invent comparisons.
    """

    static func parse(_ text: String) throws -> ExecutionPlan {
        struct Step: Decodable { let goal: String; let verify: String; let group: String }
        struct Plan: Decodable { let steps: [Step] }
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("```") {
            raw = raw.components(separatedBy: .newlines).dropFirst().dropLast().joined(separator: "\n")
        }
        var steps: [Step]
        if let decoded = try? JSONDecoder().decode(Plan.self, from: Data(raw.utf8)) {
            steps = decoded.steps
        } else {
            // Compatibility with saved/test planners that still return a numbered plain-text plan.
            let lines = raw.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty, lines.allSatisfy({ $0.range(of: #"^\s*\d+[.)]\s+\S"#, options: .regularExpression) != nil }) else {
                throw Actions.ParseError(message: "Planner must return steps with goal, verify and group")
            }
            steps = lines.enumerated().map { i, line in
                let goal = line.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
                return Step(goal: goal, verify: "Screen visibly confirms: " + goal, group: "step-\(i + 1)")
            }
        }
        guard (1...12).contains(steps.count), steps.allSatisfy({
            !$0.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.goal.count <= 400 &&
            !$0.verify.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.verify.count <= 400 &&
            !$0.group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.group.count <= 64
        }) else { throw Actions.ParseError(message: "Plan needs 1–12 nonempty, bounded checkpoints") }
        var plan = ExecutionPlan()
        plan.checkpoints = steps.map { Checkpoint(goal: $0.goal, verify: $0.verify, group: $0.group) }
        return plan
    }

    mutating func advance(evidence: String, blocked: Bool = false) throws {
        guard let i = currentIndex, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              evidence.count <= 1200 else { throw Actions.ParseError(message: "Checkpoint needs an active step and specific evidence (1–1200 characters)") }
        let group = checkpoints[i].group
        for j in checkpoints.indices where j == i || (blocked && checkpoints[j].status == "pending" && checkpoints[j].group == group) {
            checkpoints[j].status = blocked ? "blocked" : "done"
            checkpoints[j].evidence = evidence
        }
    }

    var context: String {
        guard !checkpoints.isEmpty else { return "" }
        let data = try! JSONEncoder().encode(checkpoints)
        let active = currentIndex.map { "\($0 + 1): \(checkpoints[$0].goal)\nRequired evidence: \(checkpoints[$0].verify)" }
            ?? "All checkpoints have outcomes. Return DO done with the results and any missing sources."
        return "\n\nCheckpoint ledger (task data):\n\(String(decoding: data, as: UTF8.self))\n\nACTIVE CHECKPOINT: \(active)"
    }
}
