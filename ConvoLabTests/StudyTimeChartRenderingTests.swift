import SwiftUI
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeChartRenderingTests: XCTestCase {
    func testEveryTimeRangeRendersVisibleCategoryBars() throws {
        for configuration in [
            (StudyTimeRange.today, Calendar.Component.hour, 24),
            (.week, .day, 7),
            (.month, .day, 31),
            (.year, .month, 12),
            (.all, .day, 2),
            (.all, .year, 5),
            (.all, .day, 100),
        ] {
            let range = try makeRange(
                key: configuration.0,
                component: configuration.1,
                bucketCount: configuration.2
            )
            let chart = StudyRhythmChart(
                analytics: range,
                generatedAt: range.endsAt,
                includedCategories: [.review],
                availableWidth: 320,
                onToggleCategory: { _ in },
                onDrillDown: nil
            )
            let renderer = ImageRenderer(
                content: chart
                    .frame(width: 390)
                    .padding(20)
                    .background(Color.white)
            )
            renderer.scale = 1

            let image = try XCTUnwrap(renderer.uiImage?.cgImage)
            XCTAssertGreaterThan(
                bluePixelCount(in: image),
                1_000,
                "Expected visible bars for \(configuration.0.rawValue)"
            )
        }
    }

    private func makeRange(
        key: StudyTimeRange,
        component: Calendar.Component,
        bucketCount: Int
    ) throws -> StudyTimeAnalyticsRange {
        let start = try Date("2021-01-01T05:00:00Z", strategy: .iso8601)
        let calendar = Calendar(identifier: .gregorian)
        let buckets = try (0..<bucketCount).map { offset in
            let bucketStart = try XCTUnwrap(
                calendar.date(byAdding: component, value: offset, to: start)
            )
            let bucketEnd = try XCTUnwrap(
                calendar.date(byAdding: component, value: 1, to: bucketStart)
            )
            return StudyTimeAnalyticsBucket(
                startsAt: bucketStart,
                endsAt: bucketEnd,
                totalMs: 3_600_000,
                categories: [StudyActivityCategory.review.rawValue: 3_600_000]
            )
        }
        return StudyTimeAnalyticsRange(
            key: key,
            startsAt: start,
            endsAt: try XCTUnwrap(
                calendar.date(byAdding: component, value: bucketCount, to: start)
            ),
            totalMs: buckets.reduce(0) { $0 + $1.totalMs },
            categories: [StudyActivityCategory.review.rawValue: bucketCount * 3_600_000],
            buckets: buckets
        )
    }

    private func bluePixelCount(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            if blue > 150, blue > red + 40, blue > green + 20 {
                count += 1
            }
        }
    }
}
