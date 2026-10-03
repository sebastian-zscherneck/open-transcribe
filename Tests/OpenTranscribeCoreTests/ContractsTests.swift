import Foundation
import Testing
@testable import OpenTranscribeCore

@Test func contractsCompile() {
    #expect(Phase.idle.rawValue == "idle")
}

// The notch UI writes these JSON files; the daemon reads them. Both sides are in different
// repositories, so the wire format itself is pinned here.

@Test func commandWireFormatMatchesWhatTheUIWrites() throws {
    let cases: [(String, Command)] = [
        ("{\"start\":{}}", .start),
        ("{\"discard\":{}}", .discard),
        ("{\"stop\":{}}", .stop),
        ("{\"markImportant\":{}}", .markImportant),
    ]
    for (json, expected) in cases {
        let decoded = try OTJSON.decoder.decode(Command.self, from: Data(json.utf8))
        #expect(decoded == expected, "\(json) should decode to \(expected)")
    }
}

@Test func sessionIdIsWrappedOnTheWire() throws {
    let json = "{\"assignSpeaker\":{\"session\":{\"raw\":\"2026-08-17T10-00-00\"},\"label\":\"Speaker A\",\"name\":\"Alex\"}}"
    let decoded = try OTJSON.decoder.decode(Command.self, from: Data(json.utf8))
    #expect(decoded == .assignSpeaker(
        session: SessionID(raw: "2026-08-17T10-00-00"), label: "Speaker A", name: "Alex"
    ))
}
