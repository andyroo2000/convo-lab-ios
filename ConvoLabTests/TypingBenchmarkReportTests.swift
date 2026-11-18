import XCTest

@testable import ConvoLab

@MainActor
final class TypingBenchmarkReportTests: XCTestCase {
  func testMedianHandlesEmptyOddAndEvenSamples() {
    XCTAssertNil(TypingBenchmarkReport.median([]))
    XCTAssertEqual(TypingBenchmarkReport.median([9, 1, 5, 3]), 4)
    XCTAssertEqual(TypingBenchmarkReport.median([1, 3, 9]), 3)
  }

  func testBridgeAlwaysRepliesWithJSONForStatusAndBusyRequests() async throws {
    let model = TypingPlaygroundModel()
    model.state = "ready"
    model.benchmarking = true
    let busy = await model.bridge(path: "/api/v1/convert", body: "{}")
    let busyJSON = try JSONSerialization.jsonObject(with: Data(busy.utf8)) as? [String: String]
    XCTAssertNotNil(busyJSON?["error"])
    model.state = "error"
    model.error = "Model failed"
    let status = await model.bridge(path: "/api/v1/engine", body: nil)
    let statusJSON = try JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: String]
    XCTAssertEqual(statusJSON?["state"], "error")
    XCTAssertEqual(statusJSON?["error"], "Model failed")
  }

  @MainActor func testReportExportsOnlyExplicitFixtureSamples() throws {
    var report = TypingBenchmarkReport(preloadMs: 12)
    report.completed = false
    report.failure = "Cancelled; partial run"
    let url = try report.save()
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertEqual(try report.save(), url)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(json["completed"] as? Bool, false)
    XCTAssertEqual((json["samples"] as? [Any])?.count, 0)
    XCTAssertEqual(
      json["modelSHA256"] as? String,
      "501f605d088f5b988791a00ae19ed46985ed7c48144f364b2f3f1f951c9b2083")
    XCTAssertNil(json["notebook"])
  }
}
