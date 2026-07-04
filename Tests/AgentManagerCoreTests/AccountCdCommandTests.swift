import XCTest
@testable import AgentManagerCore

final class AccountCdCommandTests: XCTestCase {
    private func account(home: String) -> Account {
        Account(id: "work", label: "Work", provider: .claude, home: home)
    }

    func testHomeShellQuotedWrapsSpaces() {
        let home = "/Users/x/Library/Application Support/AgentManager/homes/work"
        XCTAssertEqual(
            account(home: home).homeShellQuoted,
            "'/Users/x/Library/Application Support/AgentManager/homes/work'"
        )
    }

    func testSingleQuotedForShellEscapesEmbeddedQuote() {
        XCTAssertEqual("it's".singleQuotedForShell, "'it'\\''s'")
    }

    func testHomeShellQuotedIsPasteableForPathWithApostrophe() {
        XCTAssertEqual(
            account(home: "/Users/o'brien/home").homeShellQuoted,
            "'/Users/o'\\''brien/home'"
        )
    }
}
