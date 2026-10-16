import XCTest
import UIKit
@testable import IPhoneAgent

@MainActor final class RideComparisonTests: XCTestCase {
    private func extraction(provider: RideProvider = .uber, route: Bool = true,
                            fare: String = "$24.80", currency: String = "USD", eta: Int? = 6) -> RideExtraction {
        RideExtraction(provider: provider, routeMatches: route, standardRide: true, rideType: "UberX",
                       fareText: fare, currency: currency, pickupMinutes: eta, reason: "Visible standard fare")
    }

    func testFareNeedsMatchingRouteCurrencyAndIndependentOCR() throws {
        let valid = try extraction().validated(for: .uber, ocr: ["$24.80"], at: Date(), evidence: "uber.jpg")
        XCTAssertEqual(valid.amount, Decimal(string: "24.80"))
        for invalid in [extraction(provider: .lyft), extraction(route: false), extraction(currency: "CAD"),
                        extraction(fare: "$24–30"), extraction(fare: "$0.00"), extraction(eta: -1)] {
            XCTAssertThrowsError(try invalid.validated(for: .uber, ocr: [invalid.fareText!], at: Date(), evidence: "uber.jpg"))
        }
        XCTAssertThrowsError(try extraction().validated(for: .uber, ocr: ["$124.80"], at: Date(), evidence: "uber.jpg"))
        XCTAssertThrowsError(try extraction().validated(for: .uber, ocr: ["$24.80"], at: Date(), evidence: ""))
    }

    func testTripRejectsEmptyOrMultilineAndPreservesSameAddresses() throws {
        XCTAssertThrowsError(try RideTrip(pickup: " ", destination: "Ferry Building"))
        XCTAssertThrowsError(try RideTrip(pickup: "Home\nBook now", destination: "Ferry Building"))
        let trip = try RideTrip(pickup: " 1 Market Street, San Francisco ", destination: "Ferry Building, San Francisco")
        for provider in RideProvider.allCases {
            XCTAssertTrue(trip.task(for: provider).contains(trip.pickup))
            XCTAssertTrue(trip.task(for: provider).contains(trip.destination))
            XCTAssertTrue(trip.task(for: provider).contains("NEVER book"))
        }
    }

    func testStaleAndMixedCurrencyQuotesAreNeverRanked() throws {
        let time = Date()
        var quote = try extraction().validated(for: .uber, ocr: ["$24.80"], at: time, evidence: "uber.jpg")
        var report = RideReport(id: UUID(), trip: try RideTrip(pickup: "A", destination: "B"), startedAt: time, quotes: [quote])
        XCTAssertNotNil(report.lowestObserved(at: time))
        XCTAssertNil(report.lowestObserved(at: time.addingTimeInterval(301)))
        XCTAssertNil(report.lowestObserved(at: time.addingTimeInterval(-1)))
        quote.currency = "CAD"; report.quotes = [quote]
        XCTAssertNil(report.lowestObserved(at: time))
    }

    func testProviderFailureKeepsPartialResultsAndWritesReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RideComparisonController(root: root)
        let trip = try RideTrip(pickup: "1 Market Street", destination: "Ferry Building")
        var visits: [RideProvider] = []
        await controller.compare(trip) { provider, receivedTrip, _ in
            XCTAssertEqual(receivedTrip, trip)
            visits.append(provider)
            if provider == .lyft { throw RideError("Login required") }
            return RideQuote(provider: provider, status: .unreadable, capturedAt: Date(), reason: "No readable fare")
        }
        XCTAssertEqual(visits, RideProvider.allCases)
        XCTAssertEqual(controller.report?.quotes.count, 3)
        XCTAssertEqual(controller.report?.quotes[1].status, .unavailable)
        XCTAssertEqual(controller.report?.quotes[1].reason, "Login required")
        XCTAssertFalse(controller.running)
        XCTAssertNotNil(controller.report?.finishedAt)
        let data = try Data(contentsOf: XCTUnwrap(controller.folder).appendingPathComponent("comparison.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(RideReport.self, from: data).quotes.count, 3)
    }

    func testReloadRestoresSavedReportWithoutStartingAutomation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RideComparisonController(root: root)
        await controller.compare(try RideTrip(pickup: "A", destination: "B")) { provider, _, _ in
            RideQuote(provider: provider, status: .unavailable, capturedAt: Date(), reason: "Not installed")
        }
        let restored = RideComparisonController(root: root)
        XCTAssertEqual(restored.report?.id, controller.report?.id)
        XCTAssertEqual(restored.report?.quotes.count, 3)
        XCTAssertFalse(restored.running)
        XCTAssertNil(restored.current)
    }

    func testCancellationDuringProviderWaitStopsSequence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RideComparisonController(root: root)
        let entered = expectation(description: "provider entered")
        let trip = try RideTrip(pickup: "A", destination: "B")
        var visits: [RideProvider] = []
        let job = Task {
            await controller.compare(trip) { provider, _, _ in
                visits.append(provider)
                entered.fulfill()
                try await Task.sleep(for: .seconds(30))
                return RideQuote(provider: provider, status: .unavailable, capturedAt: Date(), reason: "No quote")
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        job.cancel()
        await job.value
        XCTAssertEqual(visits, [.uber])
        XCTAssertEqual(controller.report?.quotes.first?.status, .stopped)
        XCTAssertFalse(controller.running)
    }

    func testLocalOCRReadsFareAndUsesTopLeftCoordinates() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
            ("$24.80" as NSString).draw(at: CGPoint(x: 80, y: 90), withAttributes: [
                .font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black
            ])
        }
        let lines = try await RideOCR.read(XCTUnwrap(image.jpegData(compressionQuality: 1)))
        let fare = try XCTUnwrap(lines.first { $0.text == "$24.80" })
        XCTAssertLessThan(fare.y, 0.25)
        XCTAssertGreaterThan(fare.width, 0)
    }

    func testStopDoesNotOpenTheNextProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RideComparisonController(root: root)
        var visits: [RideProvider] = []
        await controller.compare(try RideTrip(pickup: "A", destination: "B")) { provider, _, _ in
            visits.append(provider)
            throw CancellationError()
        }
        XCTAssertEqual(visits, [.uber])
        XCTAssertEqual(controller.report?.quotes.first?.status, .stopped)
        XCTAssertFalse(controller.running)
    }

    func testBookingTapAndKeyboardAreBlockedButSearchIsAllowed() throws {
        let lines = [RideTextLine(text: "Request UberX", x: 0.2, y: 0.8, width: 0.6, height: 0.05),
                     RideTextLine(text: "Search", x: 0.4, y: 0.2, width: 0.2, height: 0.04)]
        XCTAssertThrowsError(try RideOCR.check(["action": .str("tap"), "x": .int(500), "y": .int(825)], lines: lines))
        XCTAssertThrowsError(try RideOCR.check(["action": .str("key"), "combo": .str("enter")], lines: lines))
        XCTAssertThrowsError(try RideOCR.check(["action": .str("type"), "text": .str("A\n")], lines: lines))
        XCTAssertThrowsError(try RideOCR.check(["action": .str("tap")], lines: []))
        XCTAssertNoThrow(try RideOCR.check(["action": .str("tap"), "x": .int(500), "y": .int(220)], lines: lines))
    }

    func testGuardRunsBeforeHIDAndPreventsBatchedActions() async throws {
        let model = FakeModel { _ in "THINK: search then book\nDO: tap 500 220\nDO: tap 500 825" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        agent.beforePerform = { _, _ in throw RideError("blocked") }
        let actions = try await agent.nextActions()
        XCTAssertEqual(actions.count, 1)
        do { _ = try await agent.step(); XCTFail("Guard must reject the gesture") } catch { }
        XCTAssertTrue(phone.calls.isEmpty)
    }
}
