import XCTest
@testable import ConvoLab

final class ClientIdentifierTests: XCTestCase {
    @MainActor
    func testULIDsUseCanonicalLengthAndAlphabet() {
        let identifier = ClientIdentifier.ulid()

        XCTAssertEqual(identifier.count, 26)
        XCTAssertNotNil(identifier.range(
            of: #"^[0-9A-HJKMNP-TV-Z]{26}$"#,
            options: .regularExpression
        ))
    }
}
