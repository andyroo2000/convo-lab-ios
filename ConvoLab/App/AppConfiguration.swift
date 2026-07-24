import Foundation

struct AppConfiguration: Sendable {
    let apiBaseURL: URL

    static func load(bundle: Bundle = .main) -> AppConfiguration {
        guard
            let value = bundle.object(forInfoDictionaryKey: "APIBaseURL") as? String,
            let url = URL(string: value),
            url.host != nil
        else {
            preconditionFailure("APIBaseURL is missing or invalid. Check Config/*.xcconfig.")
        }

        return AppConfiguration(apiBaseURL: url)
    }
}

