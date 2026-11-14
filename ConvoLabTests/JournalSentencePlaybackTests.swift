import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalSentencePlaybackTests: XCTestCase {
    private let sentences = [
        JournalSentenceTiming(text: "映画を見た。", start: 0, end: 2),
        JournalSentenceTiming(text: "楽しかった。", start: 2, end: 4)
    ]

    func testHighlightMovesAtTheExactSentenceBoundaryAndClearsAtEnd() {
        XCTAssertEqual(JournalSentenceTimeline.current(sentences, at: 1.99), 0)
        XCTAssertEqual(JournalSentenceTimeline.current(sentences, at: 2), 1)
        XCTAssertNil(JournalSentenceTimeline.current(sentences, at: 4))
    }

    func testArrowsMoveExactlyOneSentenceAndClampAtBothEnds() {
        XCTAssertEqual(JournalSentenceTimeline.adjacent(sentences, at: 0, direction: -1), 0)
        XCTAssertEqual(JournalSentenceTimeline.adjacent(sentences, at: 1, direction: 1), 2)
        XCTAssertEqual(JournalSentenceTimeline.adjacent(sentences, at: 3, direction: -1), 0)
        XCTAssertEqual(JournalSentenceTimeline.adjacent(sentences, at: 4, direction: 1), 2)
        XCTAssertNil(JournalSentenceTimeline.adjacent([], at: 0, direction: 1))
    }

    func testSentenceBoundariesTolerateAudioSampleRounding() {
        let three = sentences + [JournalSentenceTiming(text: "また見たい。", start: 4, end: 6)]
        XCTAssertEqual(JournalSentenceTimeline.current(three, at: 1.9999), 1)
        XCTAssertEqual(JournalSentenceTimeline.adjacent(three, at: 1.9999, direction: 1), 4)
        XCTAssertEqual(JournalSentenceTimeline.adjacent(three, at: 1.9999, direction: -1), 0)
    }

    func testFinishedRecordingCanReplayWithoutDownloading() async throws {
        let player = JournalAudioPlayer()
        let recording = JournalTimedRecording(audioBase64: silentWave().base64EncodedString(), sentences: sentences)
        await player.toggleTimed { recording }
        defer { player.stop() }
        player.seek(player.duration - 0.05)
        for _ in 0..<30 {
            if !player.isPlaying { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, player.duration)
        XCTAssertEqual(player.sentences, sentences)
        await player.toggleTimed { XCTFail("Finished recording must be reused"); return recording }
        XCTAssertTrue(player.isPlaying)
        XCTAssertLessThan(player.position, 0.5)
    }

    func testPauseDoesNotResumeOrDiscardTheRecording() async {
        let player = JournalAudioPlayer()
        let recording = JournalTimedRecording(audioBase64: silentWave().base64EncodedString(), sentences: sentences)
        await player.toggleTimed { recording }
        defer { player.stop() }
        player.seek(2)
        player.pause()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, 2, accuracy: 0.1)
        XCTAssertEqual(player.sentences, sentences)
        player.pause()
        XCTAssertFalse(player.isPlaying)
        await player.toggleTimed { XCTFail("Pause must keep the recording"); return recording }
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.position, 2, accuracy: 0.1)
    }

    func testTextRangesUseUTF16AndRejectMismatchedText() {
        let emoji = [JournalSentenceTiming(text: "映画🎬。", start: 0, end: 1), JournalSentenceTiming(text: "好き。", start: 1, end: 2)]
        XCTAssertEqual(JournalSentenceTimeline.ranges(emoji, text: "映画🎬。好き。"), [NSRange(location: 0, length: 5), NSRange(location: 5, length: 3)])
        XCTAssertEqual(JournalSentenceTimeline.ranges(emoji, text: "違う文章。"), [])
    }

    func testSeekingPreservesPausedAndPlayingStateAndUpdatesHighlightPosition() async throws {
        let player = JournalAudioPlayer()
        let recording = JournalTimedRecording(audioBase64: silentWave().base64EncodedString(), sentences: sentences)
        await player.toggleTimed { recording }
        defer { player.stop() }
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(player.isPlaying)
        player.moveSentence(1)
        XCTAssertEqual(player.position, 2, accuracy: 0.05)
        XCTAssertTrue(player.isPlaying)
        await player.toggleTimed { XCTFail("Loaded audio must not download again"); return recording }
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.engaged)
        player.moveSentence(-1)
        XCTAssertEqual(player.position, 0)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.engaged)
        player.stop()
        XCTAssertTrue(player.sentences.isEmpty)
        XCTAssertEqual(player.position, 0)
    }

    func testTimedQuestionRequestUsesAuthenticatedPostAndRejectsAccountSwitch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: configuration))
        api.setAccessToken("first")
        let service = JournalService(api: api)
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.timeoutInterval, 120)
            XCTAssertEqual(request.url?.path, "/api/journal/entries/01arz3ndektsv4rrffq69g5fav/questions/01arz3ndektsv4rrffq69g5fax/audio/timed")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer first")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"data":{"audioBase64":"SUQz","sentences":[]}}"#.utf8))
        }
        let result = try await service.timedQuestionAudio(entryID: "01arz3ndektsv4rrffq69g5fav", questionID: "01arz3ndektsv4rrffq69g5fax")
        XCTAssertEqual(try result.audioData(), Data("ID3".utf8))
        api.setAccessToken("other")
        do { _ = try await service.timedQuestionAudio(entryID: "01arz3ndektsv4rrffq69g5fav", questionID: "01arz3ndektsv4rrffq69g5fax"); XCTFail("Session must be rejected") }
        catch { XCTAssertNotNil(error as? APIClientError) }
    }

    func testLeavingWhileTimedAudioLoadsCannotRestoreStaleSentenceLinks() async {
        let requested = expectation(description: "Timed audio requested")
        var continuation: CheckedContinuation<JournalTimedRecording, Never>?
        let player = JournalAudioPlayer()
        let task = Task {
            await player.toggleTimed {
                await withCheckedContinuation { continuation = $0; requested.fulfill() }
            }
        }
        await fulfillment(of: [requested], timeout: 2)
        player.stop()
        continuation?.resume(returning: JournalTimedRecording(audioBase64: silentWave().base64EncodedString(), sentences: sentences))
        await task.value
        XCTAssertTrue(player.sentences.isEmpty)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.preparing)
        XCTAssertNil(player.errorMessage)
    }

    private func silentWave() -> Data {
        let count = 4 * 8000 * 2
        var data = Data("RIFF".utf8)
        func number(_ value: UInt32, bytes: Int) { for shift in 0..<bytes { data.append(UInt8((value >> (shift * 8)) & 255)) } }
        number(UInt32(count + 36), bytes: 4)
        data.append(Data("WAVEfmt ".utf8)); number(16, bytes: 4)
        number(1, bytes: 2); number(1, bytes: 2); number(8000, bytes: 4); number(16000, bytes: 4)
        number(2, bytes: 2); number(16, bytes: 2)
        data.append(Data("data".utf8)); number(UInt32(count), bytes: 4)
        data.append(Data(repeating: 0, count: count))
        return data
    }
}
