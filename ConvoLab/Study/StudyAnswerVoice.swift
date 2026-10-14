import Foundation

struct StudyAnswerVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String

    static let defaultVoice = StudyAnswerVoice(
        id: "fishaudio:abb4362e736f40b7b5716f4fafcafa9f",
        name: "Ren",
        detail: "Wiry and assertive"
    )

    static let japanese: [StudyAnswerVoice] = [
        .init(
            id: "fishaudio:0dff3f6860294829b98f8c4501b2cf25",
            name: "Nakamura",
            detail: "Cool and restrained"
        ),
        .init(
            id: "fishaudio:875668667eb94c20b09856b971d9ca2f",
            name: "Sato",
            detail: "Warm izakaya owner"
        ),
        defaultVoice,
        .init(
            id: "fishaudio:b3e9710c629a472f8224e1c4975a869e",
            name: "Otani",
            detail: "Bookish and thoughtful"
        ),
        .init(
            id: "fishaudio:72416f3ff95541d9a2456b945e8a7c32",
            name: "Rina",
            detail: "Cool and stern"
        ),
        .init(
            id: "fishaudio:e6e20195abee4187bddfd1a2609a04f9",
            name: "Yu",
            detail: "Polished politician"
        ),
        .init(
            id: "fishaudio:351aa1e3ef354082bc1f4294d4eea5d0",
            name: "Hana",
            detail: "Cute and soft-spoken"
        ),
        .init(
            id: "fishaudio:694e06f2dcc44e4297961d68d6a98313",
            name: "Mika",
            detail: "College student"
        ),
        .init(
            id: "fishaudio:9639f090aa6346329d7d3aca7e6b7226",
            name: "Yumi",
            detail: "Young Tokyo mother"
        ),
        .init(
            id: "fishaudio:297a6fd278df47c3b9da9bfdf55ac89a",
            name: "Satoru",
            detail: "Calm and relaxed narrator"
        ),
        .init(
            id: "fishaudio:21c74cb823fa45ef996ccc91cd6038b6",
            name: "おれ",
            detail: "Energetic and authoritative"
        ),
        .init(
            id: "fishaudio:434dd33d4d3c4cf68b98e3d7f25f31ab",
            name: "チャラ男2",
            detail: "Cheerful and animated"
        ),
        .init(
            id: "fishaudio:9bf6608381a34f47ada3753f2e9f9381",
            name: "ナレーター男性",
            detail: "Deep and measured narrator"
        ),
        .init(
            id: "fishaudio:fce788bf2cbd4698ba32e599f6f0989f",
            name: "チェスター・ベニントン",
            detail: "Gentle and warm storyteller"
        ),
        .init(
            id: "fishaudio:934ad2c65f604b0e84b432a560e3008a",
            name: "隊長さん音声",
            detail: "Calm and soothing narrator"
        ),
        .init(
            id: "fishaudio:b2d9d8db057042688a5e318b8f405bc2",
            name: "Kyoko",
            detail: "Polite and composed"
        ),
        .init(
            id: "fishaudio:35c8e5ae5239435f8d9c26c86802b86d",
            name: "丁寧なヘルプデスク",
            detail: "Clear and considerate"
        ),
        .init(
            id: "fishaudio:030fda5bec284b038ad930effd150f94",
            name: "ゆあ",
            detail: "Bright and conversational"
        ),
        .init(
            id: "fishaudio:63bc41e652214372b15d9416a30a60b4",
            name: "元気な女性v2",
            detail: "Cheerful and enthusiastic"
        ),
    ]
}
