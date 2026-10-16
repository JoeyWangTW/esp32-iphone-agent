import Foundation
import Vision

struct RideTextLine: Codable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum RideOCR {
    static func read(_ jpeg: Data) async throws -> [RideTextLine] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: jpeg).perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5 else { return nil }
                let b = observation.boundingBox
                return RideTextLine(text: candidate.string, x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            }.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        }.value
    }

    /// Conservative additional guard, not a proof that an arbitrary screen action cannot book.
    static func check(_ action: JObject, lines: [RideTextLine]) throws {
        let name = action["action"]?.str ?? ""
        guard !lines.isEmpty else { throw RideError("No legible screen text; ride control paused.") }
        if name == "key" { throw RideError("Keyboard shortcuts are disabled during ride comparison. Tap the search control instead.") }
        if name == "type", let text = action["text"]?.str,
           text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw RideError("Control characters are disabled during ride comparison.")
        }
        if ["path", "circle"].contains(name) { throw RideError("Drawing gestures are disabled during ride comparison.") }
        if name == "tap" {
            let x = (action["x"]?.double ?? -1000) / 1000
            let y = (action["y"]?.double ?? -1000) / 1000
            let blocked = lines.contains { line in
                let risky = line.text.range(of: #"\b(request|book|reserve|confirm|pay|subscribe|accept|agree|order)\b|\bchoose\s+(uber|lyft|waymo)|\blet.s go\b"#,
                                            options: [.regularExpression, .caseInsensitive]) != nil
                return risky && x >= line.x - 0.15 && x <= line.x + line.width + 0.15 &&
                    y >= line.y - 0.035 && y <= line.y + line.height + 0.035
            }
            if blocked { throw RideError("Blocked a tap near a booking, payment, or confirmation control.") }
        }
    }
}
