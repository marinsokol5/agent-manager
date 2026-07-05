import XCTest
@testable import AgentManagerCore

/// `AppVersion.resolve` — the pure half of what `am --version` reports, exercised
/// without depending on `Bundle.main` (which differs under the test runner).
final class AppVersionTests: XCTestCase {
    func testPrefersBundleValueWhenPresent() {
        XCTAssertEqual(AppVersion.resolve(infoDictionary: ["CFBundleShortVersionString": "9.9.9"]), "9.9.9")
    }

    func testFallsBackWhenKeyMissingOrDictNil() {
        XCTAssertEqual(AppVersion.resolve(infoDictionary: nil), AppVersion.fallback)
        XCTAssertEqual(AppVersion.resolve(infoDictionary: [:]), AppVersion.fallback)
        XCTAssertEqual(AppVersion.resolve(infoDictionary: ["CFBundleName": "x"]), AppVersion.fallback)
    }

    /// The fallback must stay a plausible dotted version so a bare-binary
    /// `am --version` never prints something malformed.
    func testFallbackLooksLikeAVersion() {
        XCTAssertFalse(AppVersion.fallback.isEmpty)
        XCTAssertTrue(AppVersion.fallback.allSatisfy { $0.isNumber || $0 == "." })
    }
}
