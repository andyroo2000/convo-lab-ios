import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var mediaURLs: [URL] {
        switch self {
        case let .object(object):
            return object.flatMap { key, value in
                if ["url", "audioUrl", "imageUrl"].contains(key),
                   let rawURL = value.stringValue,
                   let url = URL(string: rawURL)
                {
                    return [url]
                }
                return value.mediaURLs
            }
        case let .array(values):
            return values.flatMap(\.mediaURLs)
        default:
            return []
        }
    }

    var preferredText: String? {
        switch self {
        case let .object(object):
            for key in ["cueText", "expression", "text", "answerText", "meaning", "translation"] {
                if let text = object[key]?.stringValue, !text.isEmpty {
                    return text
                }
            }
            return object.values.compactMap(\.preferredText).first
        case let .array(values):
            return values.compactMap(\.preferredText).first
        case let .string(value):
            return value
        default:
            return nil
        }
    }
}

