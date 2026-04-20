//
//  OnePasswordCLITests.swift
//  SocketTests
//
//  Pure-parser unit tests for OnePasswordCLI. We never shell out to `op`;
//  instead we feed canned JSON strings (representative of the real CLI
//  output) into the extracted static parsers and URL-match helper.
//

import XCTest
@testable import Socket

@MainActor
final class OnePasswordCLITests: XCTestCase {

    // MARK: - parseWhoami

    func testParseWhoami_signedIn() {
        let stdout = """
        {
          "url": "https://my.1password.com",
          "account_uuid": "LFSTOQTL7RHZJBOKU3KE4M5R4M",
          "email": "user@example.com",
          "user_uuid": "ABCXYZ"
        }
        """
        let parsed = OnePasswordCLI.parseWhoami(stdout)
        XCTAssertTrue(parsed.signedIn)
        XCTAssertEqual(parsed.account, "https://my.1password.com")
        XCTAssertEqual(parsed.email, "user@example.com")
    }

    func testParseWhoami_fallsBackToAccountUUIDWhenURLMissing() {
        let stdout = """
        {"account_uuid": "LFSTOQTL7RHZJBOKU3KE4M5R4M", "email": "a@b.com"}
        """
        let parsed = OnePasswordCLI.parseWhoami(stdout)
        XCTAssertTrue(parsed.signedIn)
        XCTAssertEqual(parsed.account, "LFSTOQTL7RHZJBOKU3KE4M5R4M")
        XCTAssertEqual(parsed.email, "a@b.com")
    }

    func testParseWhoami_emptyInputIsSignedOut() {
        let parsed = OnePasswordCLI.parseWhoami("")
        XCTAssertFalse(parsed.signedIn)
        XCTAssertNil(parsed.account)
        XCTAssertNil(parsed.email)
    }

    func testParseWhoami_whitespaceOnlyIsSignedOut() {
        let parsed = OnePasswordCLI.parseWhoami("   \n\t  ")
        XCTAssertFalse(parsed.signedIn)
    }

    func testParseWhoami_malformedJSONIsSignedOut() {
        let parsed = OnePasswordCLI.parseWhoami("{not json}")
        XCTAssertFalse(parsed.signedIn)
        XCTAssertNil(parsed.account)
        XCTAssertNil(parsed.email)
    }

    func testParseWhoami_missingEmailStillSignedIn() {
        // If the CLI returns JSON without an email (unusual but not impossible),
        // we still treat the user as signed in; email is just nil.
        let parsed = OnePasswordCLI.parseWhoami("{\"url\":\"https://my.1password.com\"}")
        XCTAssertTrue(parsed.signedIn)
        XCTAssertEqual(parsed.account, "https://my.1password.com")
        XCTAssertNil(parsed.email)
    }

    // MARK: - parseLoginList

    func testParseLoginList_standardEntries() {
        let stdout = """
        [
          {
            "id": "abc123",
            "title": "GitHub",
            "category": "LOGIN",
            "additional_information": "octocat",
            "urls": [{"label":"website","href":"https://github.com"}]
          },
          {
            "id": "def456",
            "title": "Bank",
            "additional_information": "jane@bank.com",
            "urls": [
              {"label":"website","href":"https://bank.example.com"},
              {"label":"backup","href":"https://bank.example.net"}
            ]
          }
        ]
        """
        let items = OnePasswordCLI.parseLoginList(stdout)
        XCTAssertEqual(items.count, 2)

        let github = items[0]
        XCTAssertEqual(github.id, "abc123")
        XCTAssertEqual(github.title, "GitHub")
        XCTAssertEqual(github.username, "octocat")
        XCTAssertEqual(github.urls, ["https://github.com"])

        let bank = items[1]
        XCTAssertEqual(bank.urls.count, 2)
        XCTAssertEqual(bank.urls, ["https://bank.example.com", "https://bank.example.net"])
    }

    func testParseLoginList_dropsItemsMissingId() {
        let stdout = """
        [
          {"title":"No ID","urls":[]},
          {"id":"ok","title":"Valid"}
        ]
        """
        let items = OnePasswordCLI.parseLoginList(stdout)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "ok")
    }

    func testParseLoginList_dropsItemsMissingTitle() {
        let stdout = """
        [{"id":"abc"}]
        """
        XCTAssertEqual(OnePasswordCLI.parseLoginList(stdout).count, 0)
    }

    func testParseLoginList_missingUsernameIsNil() {
        let stdout = """
        [{"id":"x","title":"X","urls":[{"href":"https://x.com"}]}]
        """
        let item = OnePasswordCLI.parseLoginList(stdout).first
        XCTAssertNotNil(item)
        XCTAssertNil(item?.username)
    }

    func testParseLoginList_missingUrlsIsEmptyArray() {
        let stdout = """
        [{"id":"x","title":"X"}]
        """
        let item = OnePasswordCLI.parseLoginList(stdout).first
        XCTAssertEqual(item?.urls, [])
    }

    func testParseLoginList_emptyArray() {
        XCTAssertEqual(OnePasswordCLI.parseLoginList("[]").count, 0)
    }

    func testParseLoginList_malformedJSONReturnsEmpty() {
        XCTAssertEqual(OnePasswordCLI.parseLoginList("not json").count, 0)
    }

    func testParseLoginList_objectInsteadOfArrayReturnsEmpty() {
        XCTAssertEqual(OnePasswordCLI.parseLoginList("{\"id\":\"x\"}").count, 0)
    }

    // MARK: - matchesHost

    func testMatchesHost_exactHost() {
        XCTAssertTrue(OnePasswordCLI.matchesHost("https://github.com", host: "github.com"))
    }

    func testMatchesHost_exactHostIgnoresCase() {
        XCTAssertTrue(OnePasswordCLI.matchesHost("https://GitHub.com", host: "github.com"))
    }

    func testMatchesHost_exactHostWithPort() {
        // URL.host strips the port so this still matches.
        XCTAssertTrue(OnePasswordCLI.matchesHost("https://github.com:443", host: "github.com"))
    }

    func testMatchesHost_pageSubdomainOfStoredDomain() {
        // 1P has example.com; page is login.example.com
        XCTAssertTrue(OnePasswordCLI.matchesHost("https://example.com", host: "login.example.com"))
    }

    func testMatchesHost_storedSubdomainOfPageDomain() {
        // 1P has login.example.com; page is example.com
        XCTAssertTrue(OnePasswordCLI.matchesHost("https://login.example.com", host: "example.com"))
    }

    func testMatchesHost_unrelatedHostIsNoMatch() {
        XCTAssertFalse(OnePasswordCLI.matchesHost("https://github.com", host: "gitlab.com"))
    }

    func testMatchesHost_partialStringIsNotMatch() {
        // "hub.com" should NOT match "github.com" — we compare hosts not substrings.
        XCTAssertFalse(OnePasswordCLI.matchesHost("https://github.com", host: "hub.com"))
    }

    func testMatchesHost_unparseableURLFallsBackToSubstring() {
        // Not a parseable URL — we use substring containment as last resort.
        XCTAssertTrue(OnePasswordCLI.matchesHost("random-text-github.com-more", host: "github.com"))
        XCTAssertFalse(OnePasswordCLI.matchesHost("random-text", host: "github.com"))
    }

    // MARK: - detectBinary

    func testDetectBinary_returnsNilOrValidPath() {
        // We can't assert presence on all test machines, but if it returns a
        // URL, the file must actually be executable.
        if let url = OnePasswordCLI.detectBinary() {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path),
                          "detectBinary() returned \(url.path) but it's not executable")
        }
    }
}
