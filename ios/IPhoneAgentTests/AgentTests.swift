import XCTest
@testable import IPhoneAgent

/// Port of server/tests/test_agent.py.
@MainActor final class AgentTests: XCTestCase {
    func testFactsSurviveHistoryWindowReplanAndReconnect() async throws {
        let actor = FakeModel { n in n == 1 ? """
            THINK: Lyft quote is visible; Waymo remains.
            MEMORY: {"key":"Lyft","value":"Standard to test destination: USD 8.95","status":"done"}
            MEMORY: {"key":"Waymo","value":"Check same destination","status":"pending"}
            DO: home
            """ : "THINK: Continue to Waymo\nDO: wait" }
        let planner = FakeModel { _ in "1. Continue with Waymo; Lyft is already checked." }
        let screen = FakeScreen()
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: actor, planner: planner, trace: nil)
        _ = try await agent.nextActions()
        for i in 0..<12 {
            agent.steps.append(["action": .str("tap"), "x": .int(i), "y": .int(i)])
        }
        _ = try await agent.nextActions()
        XCTAssertTrue(actor.prompts.last!.contains("USD 8.95"))
        XCTAssertTrue(actor.prompts.last!.contains("\"status\":\"done\""))
        XCTAssertTrue(actor.prompts.last!.contains("\"status\":\"pending\""))
        screen.live = false
        let reconnect = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(10))
            screen.live = true
        }
        try await agent.replan(stuck: true)
        try await reconnect.value
        XCTAssertTrue(planner.prompts.last!.contains("USD 8.95"))
        XCTAssertTrue(planner.prompts.last!.contains("connection was lost and restored"))
        XCTAssertEqual(agent.memory.notes.count, 2)
    }

    func testObservationSurvivesRejectedRepeatedActionAndGestureFailure() async throws {
        let actor = FakeModel { n in n == 1 ? """
            THINK: Result is visible.
            MEMORY: {"key":"result","value":"Observed quote USD 8.95","status":"done"}
            DO: home
            """ : "THINK: Different move\nDO: tap 100 200" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        agent.steps = [["action": .str("home"), "changed": .bool(false)]]
        agent.beforePerform = { _, _ in throw DeviceError(message: "disconnected") }
        do { _ = try await agent.step(); XCTFail("Expected gesture failure") } catch {}
        XCTAssertEqual(actor.prompts.count, 2)
        XCTAssertTrue(actor.prompts[1].contains("USD 8.95"))
        XCTAssertEqual(agent.memory.notes.first?.status, "done")
    }

    func testInvalidMemoryRetriesWithoutGestureOrPartialCommit() async throws {
        let actor = FakeModel { n in n == 1 ? """
            MEMORY: {"key":"valid","value":"Should not partially commit","status":"done"}
            MEMORY: {"key":"broken","value":"bad","status":"maybe"}
            DO: tap 500 500
            """ : "THINK: Stop\nDO: done unavailable" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        let done = try await agent.step()
        XCTAssertTrue(done)
        XCTAssertTrue(phone.calls.isEmpty)
        XCTAssertTrue(agent.memory.notes.isEmpty)
        XCTAssertTrue(actor.prompts[1].contains("Reply format error"))
    }

    func testMemoryResetsWhenClearedAndAtNewRun() async throws {
        let model = FakeModel { _ in "MEMORY: {\"key\":\"quote\",\"value\":\"old fare\",\"status\":\"done\"}\nDO: done ok" }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        _ = try await agent.nextActions()
        XCTAssertFalse(agent.memory.notes.isEmpty)
        try agent.clear()
        XCTAssertTrue(agent.memory.notes.isEmpty)
        _ = try await agent.nextActions()
        try agent.start("New task")
        XCTAssertTrue(agent.memory.notes.isEmpty)
        agent.stop()
        while agent.running { await Task.yield() }
        XCTAssertTrue(agent.memory.notes.isEmpty)
    }

    func testMemoryCorrectionsBoundsAndProvenance() throws {
        let date = Date(timeIntervalSince1970: 100)
        let first = try RunMemory().updating(from: "MEMORY: {\"key\":\"Quote\",\"value\":\"Unknown\",\"status\":\"pending\"}", observedAt: date)
        let next = try first.updating(from: "MEMORY: {\"key\":\" quote \",\"value\":\"USD 9.50\",\"status\":\"done\"}", observedAt: date.addingTimeInterval(10))
        XCTAssertEqual(next.notes.count, 1)
        XCTAssertEqual(next.notes[0].value, "USD 9.50")
        XCTAssertEqual(next.notes[0].observedAt, date.addingTimeInterval(10))
        XCTAssertThrowsError(try next.updating(from: "MEMORY: invalid json", observedAt: date))
        XCTAssertEqual(try next.updating(from: "THINK: Continue\nDO: wait", observedAt: date).notes, next.notes)
        XCTAssertThrowsError(try next.updating(from: "MEMORY: {\"key\":\"x\",\"value\":\"\(String(repeating: "x", count: 401))\",\"status\":\"done\"}", observedAt: date))
        var full = RunMemory()
        for i in 0..<32 {
            full = try full.updating(from: "MEMORY: {\"key\":\"\(i)\",\"value\":\"value\",\"status\":\"observed\"}", observedAt: date)
        }
        XCTAssertThrowsError(try full.updating(from: "MEMORY: {\"key\":\"extra\",\"value\":\"value\",\"status\":\"observed\"}", observedAt: date))
        XCTAssertEqual(full.notes.count, 32)
    }

    func testMemoryIsArchivedWithSourceWithoutBecomingAGesture() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let trace = TraceStore(root: folder)
        trace.start(task: "Read result")
        let model = FakeModel { _ in "MEMORY: {\"key\":\"result\",\"value\":\"USD 8.95\",\"status\":\"done\"}\nDO: done USD 8.95" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: model, planner: model, trace: trace)
        _ = try await agent.step()
        let text = try String(contentsOf: trace.dir!.appendingPathComponent("steps.jsonl"), encoding: .utf8)
        let records = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(records.compactMap { $0["kind"] as? String }, ["task", "llm", "memory", "step"])
        XCTAssertNotNil(records[1]["frame"])
        XCTAssertTrue((records[2]["notes"] as? String)?.contains("USD 8.95") == true)
        XCTAssertEqual(RunStore.load(trace.dir!)?.steps.count, 1)
        XCTAssertTrue(phone.calls.isEmpty)
        XCTAssertEqual(model.prompts.count, 1)
    }

    func testScreenLostWhileModelThinksPreventsGesture() async {
        let screen = FakeScreen(), phone = FakeGestures()
        let model = FakeModel { _ in
            screen.live = false
            return "THINK: tap\nDO: tap 500 500"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        do { _ = try await agent.step(); XCTFail("Expected lost screen") }
        catch { XCTAssertTrue(error is DeviceError) }
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testPlannerTimeoutRetriesOnceAndChecksGateAgain() async throws {
        let model = TimeoutModel(failures: 1)
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        var gates = 0
        var retryShown = false
        agent.gate = { gates += 1 }
        agent.onDoing = { if case .retrying = $0 { retryShown = true } }
        try await agent.replan()
        XCTAssertEqual(model.calls, 2)
        XCTAssertEqual(gates, 2)
        XCTAssertTrue(retryShown)
        XCTAssertEqual(agent.plan, "1. Observe the screen")
    }

    func testPlannerTimeoutStopsAfterOneRetry() async {
        let model = TimeoutModel(failures: 10)
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        do { try await agent.replan(); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(ModelRequestFailure.isTimeout(error)) }
        XCTAssertEqual(model.calls, 2)
        XCTAssertTrue(agent.steps.isEmpty)
    }

    func testPlannerAndActorHaveDistinctPendingAndReceivingStates() async throws {
        let model = ProgressModel()
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        var states: [String] = []
        agent.onDoing = {
            switch $0 {
            case .waiting: states.append("waiting")
            case .planning: states.append("planning")
            case .thinking: states.append("thinking")
            default: break
            }
        }
        try await agent.replan()
        XCTAssertEqual(states.last, "planning")
        XCTAssertEqual(states.first, "waiting")
        XCTAssertNil(model.onProgress)
        states = []
        _ = try await agent.nextActions()
        XCTAssertEqual(states.first, "waiting")
        XCTAssertEqual(states.last, "thinking")
        XCTAssertFalse(states.contains("planning"))
        XCTAssertNil(model.onProgress)
    }

    func testParseSingleAction() throws {
        let acts = try Actions.parseActions("THINK: The Search pill is visible, so I tap it.\nDO: tap 500 814")
        XCTAssertEqual(acts, [["thought": .str("The Search pill is visible, so I tap it."), "thought_zh": .str(""),
                               "action": .str("tap"), "x": .int(500), "y": .int(814)]])
        XCTAssertEqual(acts[0].keys, ["thought", "thought_zh", "action", "x", "y"])
    }

    func testParseSeveralActionsKeepsThoughtOnFirst() throws {
        let acts = try Actions.parseActions("THINK: Type and search.\nDO: type Whiteboard\nDO: key enter")
        XCTAssertEqual(acts.map { $0["action"]?.str }, ["type", "key"])
        XCTAssertEqual(acts[0]["text"], .str("Whiteboard"))
        XCTAssertEqual(acts[1]["combo"], .str("enter"))
        XCTAssertNil(acts[1]["thought"])
    }

    func testParseCapsAtSixActions() throws {
        let reply = "THINK: draw\n" + (0..<10).map { "DO: tap \($0) \($0)" }.joined(separator: "\n")
        XCTAssertEqual(try Actions.parseActions(reply).count, 6)
    }

    func testParsePathAndCircle() throws {
        XCTAssertEqual(try Actions.parseCommand("path 100 200 300 400 500 600")["points"],
                       .arr([.arr([.int(100), .int(200)]), .arr([.int(300), .int(400)]), .arr([.int(500), .int(600)])]))
        XCTAssertEqual(try Actions.parseCommand("circle 500 450 200"),
                       ["action": .str("circle"), "x": .int(500), "y": .int(450), "r": .int(200)])
    }

    func testParseRejectsBadCommands() {
        for line in ["fly 1 2", "tap 500", "path 1 2 3"] {
            XCTAssertThrowsError(try Actions.parseCommand(line), line)
        }
    }

    func testParseRequiresADoLine() {
        XCTAssertThrowsError(try Actions.parseActions("THINK: I am not sure what to do."))
    }

    func testParsePlanWithAndWithoutLanguages() {
        XCTAssertTrue(Actions.parsePlan("EN:\n1. Tap Search\nZH:\n1. 点搜索") == ("1. Tap Search", "1. 点搜索"))
        XCTAssertTrue(Actions.parsePlan("1. Tap Search") == ("1. Tap Search", "1. Tap Search"))
    }

    func testCircleIsClosedAndRoundOnATallScreen() {
        let aspect = 0.46  // width / height of a portrait iPhone frame
        let pts = circle(0.5, 0.5, 0.2, aspect: aspect)
        XCTAssertEqual(pts[0].x, pts.last!.x, accuracy: 1e-9)
        XCTAssertEqual(pts[0].y, pts.last!.y, accuracy: 1e-9)
        for p in pts {  // equal radius in pixels: y offsets shrink by the aspect ratio
            XCTAssertEqual(hypot(p.x - 0.5, (p.y - 0.5) / aspect), 0.2, accuracy: 1e-9)
        }
    }

    func testActorMayNotRepeatAMoveThatChangedNothing() async throws {
        let actor = FakeModel { n in
            n == 1 ? "THINK: again\nDO: swipe 382 253 382 150" : "THINK: other\nDO: tap 1 2"
        }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        agent.steps = [["action": .str("swipe"), "x1": .int(382), "y1": .int(253), "x2": .int(382), "y2": .int(150),
                        "changed": .bool(false)]]
        let acts = try await agent.nextActions()
        XCTAssertEqual(acts[0].act["action"], .str("tap"))
        XCTAssertTrue(actor.prompts[1].contains("changed nothing"))
    }

    func testRepeatingAMoveThatKeepsChangingTheScreenIsNotStuck() {
        let agent = AgentLoop(phone: nil, screen: nil, actor: nil, planner: nil, trace: nil)
        let swipe: JObject = ["action": .str("swipe"), "x1": .int(500), "y1": .int(800), "x2": .int(500), "y2": .int(400)]
        agent.steps = [swipe.merging(["changed": .bool(true)]), swipe.merging(["changed": .bool(true)])]
        XCTAssertFalse(agent.repeating(swipe))
        agent.steps[1]["changed"] = .bool(false)  // reached the end of the list
        XCTAssertTrue(agent.repeating(swipe))
    }

    func testPreciseTapFlag() throws {
        XCTAssertEqual(try Actions.parseCommand("tap 120 640 precise"),
                       ["action": .str("tap"), "x": .int(120), "y": .int(640), "precise": .bool(true)])
        XCTAssertNil(try Actions.parseCommand("tap 120 640")["precise"])
    }

    // MARK: - beyond the Python tests

    func testHistoryIsFormattedLikePythonJSONDumps() async throws {
        let actor = FakeModel { _ in "THINK: ok\nDO: wait" }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        agent.steps = [
            ["t": .num(1), "shot": .bool(true), "action": .str("plan"), "plan": .str("1. x")],
            ["t": .num(2), "shot": .bool(true), "thought": .str("hi"), "action": .str("tap"), "x": .int(1), "y": .int(2),
             "think_s": .num(1.5), "changed": .bool(true)],
            ["t": .num(3), "shot": .bool(false), "action": .str("type"), "text": .str("café")],
        ]
        _ = try await agent.nextActions()
        XCTAssertTrue(actor.prompts[0].hasSuffix(
            "Recent actions:\n{\"action\": \"tap\", \"x\": 1, \"y\": 2} -> screen changed\n"
            + "{\"action\": \"type\", \"text\": \"caf\\u00e9\"}\n\nNext action?"))
    }

    func testPromptsAreVerbatimFromThePythonServer() throws {
        let agentPy = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../server/hidagent/agent.py").standardized
        guard let source = try? String(contentsOf: agentPy, encoding: .utf8) else {
            throw XCTSkip("server source not reachable from the test runner")
        }
        XCTAssertTrue(source.contains("PLANNER_PROMPT = \"\"\"" + Prompts.planner + "\"\"\""))
        XCTAssertTrue(source.contains("ACTOR_PROMPT = \"\"\"" + Prompts.actorServer + "\"\"\""))
    }

    func testRunStopsAfterThreeErrorsInARow() async {
        let model = FakeModel { n in n == 1 ? "1. do it" : "no action here" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        await agent.run()
        XCTAssertEqual(agent.steps.last?["action"], .str("fail"))
        XCTAssertEqual(agent.steps.last?["reason"], .str("3 errors in a row"))
    }

    func testRunFinishesOnDone() async {
        let model = FakeModel { n in n == 1 ? "1. go home" : n == 2 ? "THINK: home\nDO: home" : "THINK: there\nDO: done ok" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        await agent.run()
        XCTAssertEqual(phone.calls, ["home"])
        XCTAssertEqual(agent.steps.map { $0["action"]?.str }, ["plan", "home", "done"])
        XCTAssertEqual(agent.steps.last?["answer"], .str("ok"))
    }
}

// MARK: - fakes

@MainActor final class FakeModel: ChatModel {
    let model = "fake"
    private(set) var prompts: [String] = []
    private let reply: (Int) -> String

    init(_ reply: @escaping (Int) -> String) { self.reply = reply }

    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        prompts.append(text)
        return ChatResult(text: reply(prompts.count), firstToken: nil, total: 0)
    }
}

@MainActor final class FakeScreen: ScreenSource {
    var live = true
    var frame: Data? = Data([0xff, 0xd8])
    var updated = 0.0
    var capturedAt = 0.0
    var aspect = 0.46
}

@MainActor final class FakeDevice: HIDDevice {
    var links = 1
    var connected = true
    var sent: [String] = []
    func send(_ command: String) async throws -> String { sent.append(command); return "" }
    func waitConnected(_ timeout: TimeInterval) async -> Bool { connected }
}

@MainActor final class FakeGestures: Gestures {
    let device: HIDDevice = FakeDevice()
    var calls: [String] = []
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws { calls.append("tap") }
    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool) async throws { calls.append("swipe") }
    func drag(_ points: [CGPoint], hold: Bool) async throws { calls.append("drag") }
    func type(_ text: String) async throws { calls.append("type") }
    func key(_ combo: String) async throws { calls.append("key") }
    func goHome() async throws { calls.append("home") }
    func goBack() async throws { calls.append("back") }
    func reset() async throws { calls.append("reset") }
}

@MainActor private final class TimeoutModel: ChatModel {
    let model = "timeout-test"
    let failures: Int
    var calls = 0
    init(failures: Int) { self.failures = failures }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        calls += 1
        if calls <= failures { throw URLError(.timedOut) }
        return ChatResult(text: "1. Observe the screen", total: 0)
    }
}

@MainActor private final class ProgressModel: ChatModel, ModelProgressReporting {
    let model = "progress-test"
    var onProgress: ((ModelResponseProgress) -> Void)?
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        onProgress?(.waiting)
        onProgress?(.receiving)
        return ChatResult(text: text.contains("Initial task plan:") ? "1. Observe the screen" : "THINK: Wait for the screen\nDO: wait", total: 0)
    }
}
