#if DEBUG
import SwiftData
import SwiftUI

struct UITestLessonAudioFixture: View {
    @State private var composition = LessonAudioFixtureComposition()

    var body: some View {
        NavigationStack {
            StudySessionView(store: composition.store, player: composition.player, mode: .lessons)
                .safeAreaInset(edge: .bottom) {
                    Text("Playback probe")
                        .font(.caption2)
                        .accessibilityIdentifier("LessonFixturePlayback")
                        .accessibilityValue(playbackDescription)
                }
        }
        .modelContainer(composition.container)
    }

    private var playbackDescription: String {
        guard composition.player.isPlaying else { return "idle" }
        let card = ["first", "last"].first {
            composition.player.isCurrent("study-lesson-\($0)")
        }
        return "playing:\(card ?? "other")"
    }
}

@MainActor
private final class LessonAudioFixtureComposition {
    // Keep SwiftData alive for the complete fixture presentation.
    let container: ModelContainer
    let store: StudyStore
    let player = StudyAudioPlayer(isLongFormAudioPlaying: { false })

    init() {
        container = try! Persistence.makeContainer(inMemory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LessonAudioFixtureProtocol.self]
        let api = APIClient(
            baseURL: URL(string: "https://lesson-audio.ui-tests.invalid")!,
            session: URLSession(configuration: configuration)
        )
        api.setAccessToken("lesson-audio-fixture")
        let media = MediaCache(initialUserID: -209, api: api, context: container.mainContext)
        store = StudyStore(initialUserID: -209, api: api, context: container.mainContext, mediaCache: media)
    }
}

private nonisolated final class LessonAudioFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let payload: Data
        let mime: String
        switch url.path {
        case "/api/study/lessons/start":
            payload = Self.lessonResponse
            mime = "application/json"
        case "/audio/first.wav", "/audio/last.wav":
            payload = Self.silentWave
            mime = "audio/wav"
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static var lessonResponse: Data {
        let cards = [
            card(id: "first", type: "production", audio: "first.wav"),
            card(id: "silent", type: "recognition", audio: nil),
            card(id: "unavailable", type: "cloze", audio: "unavailable.wav"),
            card(id: "last", type: "cloze", audio: "last.wav"),
        ]
        let session: [String: Any] = [
            "overview": ["dueCount": 0, "newCount": 4, "reviewCount": 0,
                         "newCardsPerDay": 10, "newCardsAvailableToday": 4, "lessonBatchSize": 4],
            "cards": cards,
        ]
        return try! JSONSerialization.data(withJSONObject: ["data": session])
    }

    private static func card(id: String, type: String, audio: String?) -> [String: Any] {
        var answer: [String: Any] = ["expression": "日本語", "meaning": "Fixture \(id)"]
        if let audio {
            answer["answerAudio"] = ["url": "https://lesson-audio.ui-tests.invalid/audio/\(audio)"]
        }
        return [
            "id": id, "cardType": type,
            "prompt": ["cueText": "Preview \(id)", "clozeText": "犬は{{c1::元気}}です。"],
            "answer": answer,
            "state": ["queueState": "new", "scheduler": [:], "source": [:]],
            "answerAudioSource": audio == nil ? "missing" : "imported",
            "createdAt": "2026-10-21T00:00:00Z", "updatedAt": "2026-10-21T00:00:00Z",
        ]
    }

    // A real two-minute, mono 8 kHz PCM file keeps AVPlayer active long enough
    // for native UI assertions, without depending on network audio or speakers.
    private static var silentWave: Data {
        let byteCount: UInt32 = 8_000 * 120 * 2
        var data = Data("RIFF".utf8)
        append(byteCount + 36, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(8_000), to: &data)
        append(UInt32(16_000), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(byteCount, to: &data)
        data.append(Data(repeating: 0, count: Int(byteCount)))
        return data
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
#endif
