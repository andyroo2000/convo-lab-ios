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
    ]
}
