import SwiftUI

struct RideComparisonView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var rides: RideComparisonController
    @ObservedObject var agent: AgentLoop
    @State private var pickup = ""
    @State private var destination = ""
    @State private var message: String?
    @State private var evidence: URL?
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pickup address, city, entrance", text: $pickup).focused($editing)
                    TextField("Destination address, city, entrance", text: $destination).focused($editing)
                } header: { Text("Your trip") } footer: {
                    Text("Use the keyboard microphone to dictate, then check both addresses. The same trip is used for Uber, Lyft, and Waymo.")
                }
                .disabled(rides.running || app.rideJob != nil)
                Section {
                    if rides.running || app.rideJob != nil {
                        ProgressView("Checking \(rides.current?.rawValue ?? "trip")…")
                        Button("Stop comparison", role: .destructive) { Task { await app.stopAgent() } }
                    } else {
                        Button("Compare rides", systemImage: "car.side") {
                            editing = false
                            message = app.startRideComparison(pickup: pickup, destination: destination)
                        }
                        .disabled(pickup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  agent.running || app.startingAgent)
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if let error = rides.error { Text(error).foregroundStyle(.red) }
                } footer: {
                    Text("Quote-only prototype. Keep the phone unlocked and supervise. Booking checks are best effort. The iPhone uses cellular; the board needs no internet.")
                }
                if app.help != nil { HelpPanel(app: app) }
                if let stage = app.recovering { RecoveryPanel(app: app, stage: stage) }
                if let hint = app.homeHint { Section { Text(hint) } }
                if let report = rides.report {
                    Section("Observed fares") {
                        Text("\(report.trip.pickup) → \(report.trip.destination)").font(.footnote)
                        ForEach(report.quotes) { quote in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(quote.provider.rawValue).font(.headline)
                                    Spacer()
                                    Text(quote.status == .quoted ? quote.price : quote.status.rawValue.capitalized)
                                }
                                if let type = quote.rideType { Text(type) }
                                if let minutes = quote.pickupMinutes { Text("\(minutes) min pickup") }
                                Text(quote.reason).font(.caption).foregroundStyle(.secondary)
                                Text(quote.capturedAt, style: .time).font(.caption)
                                if let file = quote.evidenceFile, let folder = rides.folder {
                                    Button("Review screenshot") { evidence = folder.appendingPathComponent(file) }
                                }
                            }
                        }
                        TimelineView(.periodic(from: .now, by: 10)) { context in
                            if let lowest = report.lowestObserved(at: context.date) {
                                Text("Lowest observed: \(lowest.provider.rawValue) · \(lowest.price)").font(.subheadline.bold())
                            }
                        }
                        if let folder = rides.folder {
                            ShareLink("Export comparison JSON", item: folder.appendingPathComponent("comparison.json"))
                        }
                    }
                    Section {
                        Text("Prices are checked sequentially, can change, and may cover different service levels. Results older than five minutes are excluded from the lowest-observed label. Review the screenshots before deciding.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Compare rides")
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: Binding(get: { evidence != nil }, set: { if !$0 { evidence = nil } })) {
                NavigationStack {
                    if let evidence, let image = UIImage(contentsOfFile: evidence.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .toolbar { Button("Done") { self.evidence = nil } }
                    }
                }
            }
        }
    }
}
