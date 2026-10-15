import Foundation

struct StudyAnswerVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let gender: Gender
    var isLegacy: Bool = false

    enum Gender: String, Sendable {
        case male = "M"
        case female = "F"
    }

    var pickerLabel: String {
        "\(name) · \(gender.rawValue) — \(detail)" + (isLegacy ? " · Legacy" : "")
    }

    static func currentVoiceLabel(for id: String) -> String {
        allJapanese.first { $0.id == id }?.pickerLabel ?? "Current voice"
    }

    static let defaultVoice = StudyAnswerVoice(
        id: "fishaudio:875668667eb94c20b09856b971d9ca2f",
        name: "Sato",
        detail: "Warm izakaya owner",
        gender: .male
    )

    static let japanese = allJapanese.filter { !$0.isLegacy }

    static let allJapanese: [StudyAnswerVoice] = [
        .init(
            id: "fishaudio:0dff3f6860294829b98f8c4501b2cf25",
            name: "Nakamura",
            detail: "Cool and restrained",
            gender: .male,
            isLegacy: true
        ),
        defaultVoice,
        .init(
            id: "fishaudio:abb4362e736f40b7b5716f4fafcafa9f",
            name: "Ren",
            detail: "Wiry and assertive",
            gender: .male,
            isLegacy: true
        ),
        .init(
            id: "fishaudio:b3e9710c629a472f8224e1c4975a869e",
            name: "Otani",
            detail: "Bookish and thoughtful",
            gender: .male,
            isLegacy: true
        ),
        .init(
            id: "fishaudio:72416f3ff95541d9a2456b945e8a7c32",
            name: "Rina",
            detail: "Cool and stern",
            gender: .female
        ),
        .init(
            id: "fishaudio:e6e20195abee4187bddfd1a2609a04f9",
            name: "Yu",
            detail: "Polished politician",
            gender: .female
        ),
        .init(
            id: "fishaudio:351aa1e3ef354082bc1f4294d4eea5d0",
            name: "Hana",
            detail: "Cute and soft-spoken",
            gender: .female
        ),
        .init(
            id: "fishaudio:694e06f2dcc44e4297961d68d6a98313",
            name: "Mika",
            detail: "College student",
            gender: .female
        ),
        .init(
            id: "fishaudio:9639f090aa6346329d7d3aca7e6b7226",
            name: "Yumi",
            detail: "Young Tokyo mother",
            gender: .female
        ),
        .init(
            id: "fishaudio:297a6fd278df47c3b9da9bfdf55ac89a",
            name: "Satoru",
            detail: "Calm and relaxed narrator",
            gender: .male,
            isLegacy: true
        ),
        .init(
            id: "fishaudio:21c74cb823fa45ef996ccc91cd6038b6",
            name: "おれ",
            detail: "Energetic and authoritative",
            gender: .male
        ),
        .init(
            id: "fishaudio:434dd33d4d3c4cf68b98e3d7f25f31ab",
            name: "チャラ男2",
            detail: "Cheerful and animated",
            gender: .male
        ),
        .init(
            id: "fishaudio:9bf6608381a34f47ada3753f2e9f9381",
            name: "ナレーター男性",
            detail: "Deep and measured narrator",
            gender: .male
        ),
        .init(
            id: "fishaudio:fce788bf2cbd4698ba32e599f6f0989f",
            name: "チェスター・ベニントン",
            detail: "Gentle and warm storyteller",
            gender: .male
        ),
        .init(
            id: "fishaudio:934ad2c65f604b0e84b432a560e3008a",
            name: "隊長さん音声",
            detail: "Calm and soothing narrator",
            gender: .male
        ),
        .init(
            id: "fishaudio:b2d9d8db057042688a5e318b8f405bc2",
            name: "Kyoko",
            detail: "Polite and composed",
            gender: .female
        ),
        .init(
            id: "fishaudio:35c8e5ae5239435f8d9c26c86802b86d",
            name: "丁寧なヘルプデスク",
            detail: "Clear and considerate",
            gender: .female
        ),
        .init(
            id: "fishaudio:030fda5bec284b038ad930effd150f94",
            name: "ゆあ",
            detail: "Bright and conversational",
            gender: .female,
            isLegacy: true
        ),
        .init(
            id: "fishaudio:63bc41e652214372b15d9416a30a60b4",
            name: "元気な女性v2",
            detail: "Cheerful and enthusiastic",
            gender: .female
        ),
    ]
}
