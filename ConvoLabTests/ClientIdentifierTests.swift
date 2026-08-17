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

    @MainActor
    func testULIDValidationRejectsUUIDAndOutOfRangePrefix() {
        XCTAssertTrue(ClientIdentifier.isULID("01J000000000000000000000F8"))
        XCTAssertTrue(ClientIdentifier.isULID("01j000000000000000000000f8"))
        XCTAssertFalse(ClientIdentifier.isULID("8D748A0E-2EE9-49A9-8A32-7B9E4187C273"))
        XCTAssertFalse(ClientIdentifier.isULID("81J000000000000000000000F8"))
    }
}
