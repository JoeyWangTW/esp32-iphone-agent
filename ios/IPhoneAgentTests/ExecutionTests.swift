import XCTest
@testable import IPhoneAgent

@MainActor final class ExecutionTests: XCTestCase {
    let plan = """
    {"steps":[
      {"goal":"Open Lyft","verify":"Lyft screen visible","group":"Lyft"},
      {"goal":"Enter destination","verify":"Requested route visible","group":"Lyft"},
      {"goal":"Read Lyft quote","verify":"Fare and option recorded","group":"Lyft"},
      {"goal":"Open Waymo","verify":"Waymo screen visible","group":"Waymo"},
      {"goal":"Compare","verify":"Compare available results and name missing ones","group":"comparison"}
    ]}
    """

    func testCheckpointOrderAndBlockedDependentSource() throws {
        var execution = try ExecutionPlan.parse(plan)
        try execution.advance(evidence: "Lyft is visible")
        XCTAssertEqual(execution.current?.goal, "Enter destination")
        try execution.advance(evidence: "Service unavailable here", blocked: true)
        XCTAssertEqual(execution.checkpoints.map(\.status), ["done", "blocked", "blocked", "pending", "pending"])
        XCTAssertEqual(execution.current?.goal, "Open Waymo")
        XCTAssertTrue(execution.context.contains("Service unavailable here"))
        XCTAssertThrowsError(try execution.advance(evidence: " "))
        try execution.advance(evidence: "Waymo results available")
        try execution.advance(evidence: "Only Waymo available")
        XCTAssertTrue(execution.complete)
        XCTAssertThrowsError(try execution.advance(evidence: "Already complete"))
    }

    func testPlanValidationAndLegacyCompatibility() throws {
        XCTAssertThrowsError(try ExecutionPlan.parse("a vague suggestion"))
        XCTAssertThrowsError(try ExecutionPlan.parse("{\"steps\":[]}"))
        XCTAssertThrowsError(try ExecutionPlan.parse("{\"steps\":[{\"goal\":\"x\",\"verify\":\"\",\"group\":\"x\"}]}"))
        XCTAssertEqual(try ExecutionPlan.parse("1. Open app\n2. Check result").checkpoints.count, 2)
        XCTAssertEqual(try ExecutionPlan.parse("```json\n" + plan + "\n```").checkpoints.count, 5)
    }

    func testMalformedInitialPlanIsCorrectedBeforeAnyAction() async throws {
        let planner = FakeModel { [plan] n in n == 1 ? "I will figure it out" : plan }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: planner, planner: planner, trace: nil)
        try await agent.replan()
        XCTAssertEqual(planner.prompts.count, 2)
        XCTAssertTrue(planner.prompts[1].contains("Invalid plan format"))
        XCTAssertTrue(phone.calls.isEmpty)
        XCTAssertEqual(agent.execution.checkpoints.count, 5)
    }

    func testPrematureDoneAndBatchAreRejectedWithoutHID() async throws {
        let actor = FakeModel { n in
            if n == 1 { return "DO: done Lyft is cheapest" }
            if n == 2 { return "DO: tap 1 2\nDO: type Lyft" }
            return "DO: checkpoint Lyft screen is visible"
        }
        let planner = FakeModel { [plan] _ in plan }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: actor, planner: planner, trace: nil)
        try await agent.replan()
        _ = try await agent.step()
        XCTAssertTrue(phone.calls.isEmpty)
        XCTAssertEqual(agent.execution.current?.goal, "Enter destination")
        XCTAssertEqual(agent.steps.last?["action"], .str("checkpoint"))
        XCTAssertTrue(actor.prompts[1].contains("remaining sources before DO done"))
        XCTAssertTrue(actor.prompts[2].contains("exactly one DO"))
    }

    func testReplanCannotResetCompletedCheckpoints() async throws {
        let actor = FakeModel { _ in "DO: checkpoint Lyft screen visible" }
        let planner = FakeModel { [plan] n in n == 1 ? plan : "Open Lyft again, then find the destination field." }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: actor, planner: planner, trace: nil)
        try await agent.replan()
        _ = try await agent.step()
        try await agent.replan(stuck: true)
        XCTAssertEqual(agent.execution.currentIndex, 1)
        XCTAssertEqual(agent.execution.checkpoints[0].status, "done")
        XCTAssertTrue(planner.prompts.last!.contains("Repair ONLY the active checkpoint"))
        XCTAssertTrue(planner.prompts.last!.contains("Lyft screen visible"))
        try agent.clear()
        XCTAssertTrue(agent.execution.checkpoints.isEmpty)
    }

    func testCheckpointActionBudgetStopsRepeatedUnproductiveNavigation() async throws {
        let actor = FakeModel { n in "DO: tap \(n) \(n)" }
        let planner = FakeModel { n in n == 1 ? "1. Open the app" : "Try a different route through Search" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FastScreen(), actor: actor, planner: planner, trace: nil)
        try await agent.replan()
        for _ in 0..<12 { _ = try await agent.step() }
        let ended = try await agent.step()
        XCTAssertTrue(ended)
        XCTAssertEqual(phone.calls.count, 12)
        XCTAssertEqual(planner.prompts.count, 2) // one repair, not a restart per tap
        XCTAssertTrue(agent.steps.last?["reason"]?.str?.contains("12 actions") == true)
    }
}

@MainActor private final class FastScreen: ScreenSource {
    let live = true
    let frame: Data? = nil
    var updated: Double { now() }
    var capturedAt: Double { now() }
    let aspect = 0.46
    func afterAction(since: Double) async {}
}
