import UIKit
import XCTest
@testable import ConvoLab

final class JournalBrandFontsTests: XCTestCase {
    @MainActor
    func testEveryBrandFontResolvesWithoutSystemFallback() {
        let names = ["Anton-Regular", "BarlowCondensed-ExtraBold", "NotoSansJP-Thin_Black",
                     "NotoSansJP-Thin_Bold", "Nunito-Black", "Inter-Regular", "Inter-Regular_SemiBold"]
        for name in names {
            XCTAssertNotNil(UIFont(name: name, size: 16), "Missing bundled font: \(name)")
        }
    }
}
