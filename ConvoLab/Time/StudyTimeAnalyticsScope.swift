import Foundation

enum StudyTimeAnalyticsScope {
    static func ranges(for range: StudyTimeRange?) -> [StudyTimeRange]? {
        guard let range else { return nil }
        return range == .week ? [.week, .month] : [range]
    }

    static func key(anchor: String, ranges: [StudyTimeRange]?) -> String {
        anchor + ":" + (ranges?.map(\.rawValue).sorted().joined(separator: ",") ?? "full")
    }

    static func query(_ ranges: [StudyTimeRange]?) -> [URLQueryItem] {
        ranges?.map { URLQueryItem(name: "ranges[]", value: $0.rawValue) } ?? []
    }
}
