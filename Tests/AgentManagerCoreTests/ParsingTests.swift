import XCTest
@testable import AgentManagerCore

final class ParsingTests: XCTestCase {
    let fm = FileManager.default

    // MARK: LoginOutputParser

    func testFirstURLStripsTrailingPunctuation() {
        let text = "Visit (https://claude.ai/oauth/authorize?code=abc123). to continue"
        XCTAssertEqual(
            LoginOutputParser.firstURL(in: text),
            "https://claude.ai/oauth/authorize?code=abc123")
    }

    func testFirstURLNilWhenAbsent() {
        XCTAssertNil(LoginOutputParser.firstURL(in: "no link here"))
    }

    func testIndicatesSuccessMatchesKnownMarkers() {
        XCTAssertTrue(LoginOutputParser.indicatesSuccess("…\nSuccessfully logged in as you@x.com"))
        XCTAssertTrue(LoginOutputParser.indicatesSuccess("Login successful"))
        XCTAssertFalse(LoginOutputParser.indicatesSuccess("Please run /login"))
    }

    // MARK: IdentityVerifier.readOAuthAccount

    func testReadsOAuthAccountEmail() throws {
        let url = tempFile(contents: #"{"oauthAccount":{"emailAddress":"me@example.com","accountUuid":"x"}}"#)
        let result = IdentityVerifier.readOAuthAccount(at: url)
        XCTAssertTrue(result.present)
        XCTAssertEqual(result.email, "me@example.com")
    }

    func testOAuthAccountAbsentWhenMissing() throws {
        let url = tempFile(contents: #"{"someOtherKey":1}"#)
        let result = IdentityVerifier.readOAuthAccount(at: url)
        XCTAssertFalse(result.present)
        XCTAssertNil(result.email)
    }

    func testOAuthAccountAbsentWhenFileMissing() {
        let missing = fm.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).json")
        XCTAssertFalse(IdentityVerifier.readOAuthAccount(at: missing).present)
    }

    // MARK: AccountID

    func testAccountIDValidation() {
        XCTAssertNoThrow(try AccountID.validate("claude-work_2"))
        XCTAssertThrowsError(try AccountID.validate(""))
        XCTAssertThrowsError(try AccountID.validate("has space"))
        XCTAssertThrowsError(try AccountID.validate("../escape"))
    }

    // MARK: Provider facts

    func testProviderIsolationEnvAndIdentityFile() {
        XCTAssertEqual(Provider.claude.configHomeEnvKey, "CLAUDE_CONFIG_DIR")
        XCTAssertEqual(Provider.claude.identityFileName, ".claude.json")
        XCTAssertEqual(Provider.claude.keychainServicePrefix, "Claude Code-credentials")
    }

    // MARK: ClaudeUsageFetcher decode (real captured payload)

    func testClaudeUsageDecodeUsesPercentNotScaledUtilization() throws {
        // Real api.anthropic.com/api/oauth/usage body: utilization is already a
        // 0–100 percent (3.0 == 3%), matching limits[].percent. Guards against the
        // old `* 100` bug that rendered 300% / 1300%.
        let json = """
        {"five_hour":{"utilization":3.0,"resets_at":"2026-06-25T12:00:00.945558+00:00"},
         "seven_day":{"utilization":13.0,"resets_at":"2026-06-30T05:00:00.945584+00:00"},
         "limits":[
           {"kind":"session","group":"session","percent":3,"resets_at":"2026-06-25T12:00:00.945558+00:00","is_active":false},
           {"kind":"weekly_all","group":"weekly","percent":13,"resets_at":"2026-06-30T05:00:00.945584+00:00","is_active":true}]}
        """
        let reading = try ClaudeUsageFetcher.decodeForTesting(Data(json.utf8))
        XCTAssertEqual(reading.primaryUsedPercent, 3)
        XCTAssertEqual(reading.secondaryUsedPercent, 13)
        XCTAssertEqual(reading.primaryRemainingPercent, 97)
        XCTAssertEqual(reading.secondaryRemainingPercent, 87)
        XCTAssertNotNil(reading.primaryResetsAt)
        XCTAssertNotNil(reading.secondaryResetsAt)
    }

    func testClaudeUsageDecodeFallsBackToWindowUtilization() throws {
        // No `limits` array → fall back to the five_hour/seven_day windows, still
        // treating utilization as an already-0–100 percent.
        let json = """
        {"five_hour":{"utilization":42.0,"resets_at":"2026-06-25T12:00:00Z"},
         "seven_day":{"utilization":7.0,"resets_at":"2026-06-30T05:00:00Z"}}
        """
        let reading = try ClaudeUsageFetcher.decodeForTesting(Data(json.utf8))
        XCTAssertEqual(reading.primaryUsedPercent, 42)
        XCTAssertEqual(reading.secondaryUsedPercent, 7)
    }

    // MARK: CodexUsageFetcher decode + account-id (real captured payload)

    func testCodexUsageDecodeReadsRateLimitWindows() throws {
        // Real chatgpt.com/backend-api/wham/usage body: used_percent are integers
        // (0–100), reset_at is epoch seconds. A fresh window reports 1% used,
        // which we floor to 0 (see usedPercent heuristic) → 100% left.
        let json = """
        {"rate_limit":{"allowed":true,
          "primary_window":{"used_percent":1,"reset_at":1782392410},
          "secondary_window":{"used_percent":34,"reset_at":1782979210}}}
        """
        let reading = try CodexUsageFetcher.decodeForTesting(Data(json.utf8))
        XCTAssertEqual(reading.primaryUsedPercent, 0)        // 1 floored to 0
        XCTAssertEqual(reading.primaryRemainingPercent, 100)
        XCTAssertEqual(reading.secondaryUsedPercent, 34)     // real usage passes through
        XCTAssertEqual(reading.primaryResetsAt, Date(timeIntervalSince1970: 1782392410))
        XCTAssertEqual(reading.secondaryResetsAt, Date(timeIntervalSince1970: 1782979210))
    }

    func testCodexUsageDecodeToleratesFractionalUsedPercent() throws {
        // If the backend ever returns used_percent as a float, round it rather
        // than dropping the window (which would otherwise show "no data").
        let json = """
        {"rate_limit":{
          "primary_window":{"used_percent":0.7,"reset_at":1782392410},
          "secondary_window":{"used_percent":"12","reset_at":1782392410.0}}}
        """
        let reading = try CodexUsageFetcher.decodeForTesting(Data(json.utf8))
        XCTAssertEqual(reading.primaryUsedPercent, 0)        // 0.7 → rounds to 1 → floored to 0
        XCTAssertEqual(reading.primaryRemainingPercent, 100)
        XCTAssertEqual(reading.secondaryUsedPercent, 12)     // numeric string, above the floor
        XCTAssertEqual(reading.secondaryResetsAt, Date(timeIntervalSince1970: 1782392410)) // float epoch
    }

    func testCodexAccountIdComesFromJWTClaimNotUserId() {
        // ChatGPT-Account-Id must be the JWT's chatgpt_account_id claim. Build a
        // synthetic unsigned JWT carrying it (no real token in tests).
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(#"{"alg":"none"}"#)
        let payload = b64url(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"2e1d5a02-acct"}}"#)
        let token = "\(header).\(payload)."
        XCTAssertEqual(CodexAuth.chatgptAccountId(accessToken: token), "2e1d5a02-acct")
        XCTAssertNil(CodexAuth.chatgptAccountId(accessToken: "not-a-jwt"))
    }

    // MARK: ClaudeCredentials expiry / needsRefresh

    func testClaudeCredentialsParsesMillisExpiryAndToken() throws {
        // Claude stores expiresAt as epoch *milliseconds*.
        let expMillis = 1_782_392_410_000.0
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":\#(Int(expMillis))}}"#
        let blob = try XCTUnwrap(ClaudeCredentials.parse(Data(json.utf8)))
        XCTAssertEqual(blob.accessToken, "sk-ant-oat01-x")
        XCTAssertEqual(blob.expiresAt, Date(timeIntervalSince1970: expMillis / 1000))
    }

    func testClaudeCredentialsNeedsRefreshHonorsMarginAndUnknowns() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func blob(_ exp: Date?) -> ClaudeCredentials.Blob { .init(accessToken: "t", expiresAt: exp) }

        // Expired and within-margin → refresh; comfortably valid → don't.
        XCTAssertTrue(ClaudeCredentials.needsRefresh(blob(now.addingTimeInterval(-10)), now: now))
        XCTAssertTrue(ClaudeCredentials.needsRefresh(blob(now.addingTimeInterval(30)), now: now, margin: 60))
        XCTAssertFalse(ClaudeCredentials.needsRefresh(blob(now.addingTimeInterval(600)), now: now, margin: 60))
        // No token at all → refresh; unknown expiry → let the request try.
        XCTAssertTrue(ClaudeCredentials.needsRefresh(nil, now: now))
        XCTAssertFalse(ClaudeCredentials.needsRefresh(blob(nil), now: now))
    }

    // MARK: KeychainGrantStore (security-CLI grant memory)

    private func makeGrantStoreFixture() throws -> (store: KeychainGrantStore, fileURL: URL, defaults: UserDefaults) {
        let dir = fm.temporaryDirectory.appendingPathComponent("am-grants-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let suite = "am-grant-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let fileURL = dir.appendingPathComponent("keychain-grants.json")
        return (KeychainGrantStore(fileURL: fileURL, legacyDefaults: defaults), fileURL, defaults)
    }

    func testKeychainGrantStoreRoundTrip() throws {
        let (store, _, _) = try makeGrantStoreFixture()
        let svc = "Claude Code-credentials-abc123"
        XCTAssertFalse(store.isGranted(svc))
        store.markGranted(svc)
        XCTAssertTrue(store.isGranted(svc))
        // Idempotent + isolated per service.
        store.markGranted(svc)
        XCTAssertFalse(store.isGranted("other-svc"))
        store.clearGranted(svc)
        XCTAssertFalse(store.isGranted(svc))
    }

    func testKeychainGrantStoreMigratesLegacyDefaultsAndSharesViaFile() throws {
        let (store, fileURL, defaults) = try makeGrantStoreFixture()
        // Older builds kept the flags in (per-process) UserDefaults; the first
        // load seeds the shared file from them and clears the legacy key.
        defaults.set(["svc-a", "svc-b"], forKey: "keychainSecurityCLIGrantedServices")
        XCTAssertTrue(store.isGranted("svc-a"))
        XCTAssertTrue(fm.fileExists(atPath: fileURL.path))
        XCTAssertNil(defaults.stringArray(forKey: "keychainSecurityCLIGrantedServices"))
        // A second store on the same file (≈ another process: app vs am vs
        // daemon) sees the same grants without any defaults of its own —
        // the cross-process gap the file replaces UserDefaults to close.
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: "am-grant-\(UUID().uuidString)"))
        let other = KeychainGrantStore(fileURL: fileURL, legacyDefaults: otherDefaults)
        XCTAssertTrue(other.isGranted("svc-b"))
        other.clearGranted("svc-b") // self-heal propagates back the same way
        XCTAssertFalse(store.isGranted("svc-b"))
        XCTAssertTrue(store.isGranted("svc-a"))
    }

    // MARK: UsageReportRenderer (am usage)

    func testUsageRendererBarAndReset() {
        // Bar fill = the given (remaining) percent.
        XCTAssertEqual(UsageReportRenderer.barString(filledPercent: 50, width: 10, color: false), "[█████░░░░░]")
        XCTAssertEqual(UsageReportRenderer.barString(filledPercent: 0, width: 4, color: false), "[░░░░]")
        XCTAssertEqual(UsageReportRenderer.barString(filledPercent: 100, width: 4, color: false), "[████]")
        XCTAssertEqual(UsageReportRenderer.barString(filledPercent: 150, width: 4, color: false), "[████]") // clamps

        let tz = TimeZone(identifier: "Europe/Amsterdam")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 10))!
        let sameDay = cal.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 18, minute: 20))!
        let otherDay = cal.date(from: DateComponents(year: 2026, month: 6, day: 26, hour: 4))!
        XCTAssertEqual(
            UsageReportRenderer.formatReset(sameDay, now: now, timeZone: tz),
            "Resets 6:20pm (in 8h 20m) · Europe/Amsterdam")
        XCTAssertEqual(
            UsageReportRenderer.formatReset(otherDay, now: now, timeZone: tz),
            "Resets Jun 26 at 4am (in 18h 0m) · Europe/Amsterdam")
        // Compact view drops the zone but keeps the relative countdown.
        XCTAssertEqual(
            UsageReportRenderer.formatReset(sameDay, now: now, timeZone: tz, includeZone: false),
            "Resets 6:20pm (in 8h 20m)")
        XCTAssertNil(UsageReportRenderer.formatReset(nil, now: now, timeZone: tz))
    }

    func testUsageRendererPlainOutput() {
        let account = Account(
            id: "claude-ms18", label: "Claude MS18", provider: .claude, home: "/tmp/x",
            status: .connected, keychainService: "svc")
        let reading = UsageReading(
            primaryUsedPercent: 24, primaryResetsAt: nil,
            secondaryUsedPercent: 50, secondaryResetsAt: nil)
        let out = UsageReportRenderer.render(account: account, reading: reading, color: false)
        XCTAssertTrue(out.contains("Current session"))
        XCTAssertTrue(out.contains("76% left")) // remaining, not used
        XCTAssertTrue(out.contains("Current week (all models)"))
        XCTAssertTrue(out.contains("50% left"))
        XCTAssertFalse(out.contains("used"))
        XCTAssertFalse(out.contains("\u{1B}[")) // no ANSI when color is off
    }

    func testUsageRendererCompactPreservesCallerOrderAndHandlesGaps() {
        func acct(_ id: String) -> Account {
            Account(id: id, label: id, provider: .claude, home: "/tmp/\(id)", status: .connected, keychainService: "s")
        }
        func reading(_ used: Int?) -> UsageReading {
            UsageReading(primaryUsedPercent: used, primaryResetsAt: nil, secondaryUsedPercent: 0, secondaryResetsAt: nil)
        }
        // Rows arrive in canonical priority order; the table must keep exactly that
        // order — including unknown/errored agents in place (no urgency re-sort).
        let rows: [UsageReportRenderer.Row] = [
            .init(account: acct("plenty"), reading: reading(10)),  // 90% left
            .init(account: acct("low"), reading: reading(80)),     // 20% left
            .init(account: acct("nodata"), reading: reading(nil)),
            .init(account: acct("errd"), reading: nil, error: "rate limited"),
        ]
        let out = UsageReportRenderer.renderCompact(rows, window: .session, color: false)
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Current session")
        // Body rows appear in caller order: plenty, low, nodata, errd.
        let body = lines.dropFirst().joined(separator: "\n")
        let iPlenty = try! XCTUnwrap(body.range(of: "plenty"))
        let iLow = try! XCTUnwrap(body.range(of: "low"))
        let iNodata = try! XCTUnwrap(body.range(of: "nodata"))
        let iErrd = try! XCTUnwrap(body.range(of: "errd"))
        XCTAssertLessThan(iPlenty.lowerBound, iLow.lowerBound)
        XCTAssertLessThan(iLow.lowerBound, iNodata.lowerBound)
        XCTAssertLessThan(iNodata.lowerBound, iErrd.lowerBound)
        XCTAssertTrue(out.contains("20% left"))
        XCTAssertTrue(out.contains("90% left"))
        XCTAssertTrue(out.contains("no data"))
        XCTAssertTrue(out.contains("! rate limited"))
    }

    // MARK: ClockStyle / Preferences

    func testClockStyleTimeString() {
        let tz = TimeZone(identifier: "Europe/Amsterdam")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let roundHour = cal.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 16))!
        let withMinutes = cal.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 16, minute: 20))!

        // 12-hour drops the minutes on round hours; 24-hour always shows "HH:mm".
        XCTAssertEqual(ClockStyle.twelveHour.timeString(roundHour, timeZone: tz), "4pm")
        XCTAssertEqual(ClockStyle.twelveHour.timeString(withMinutes, timeZone: tz), "4:20pm")
        XCTAssertEqual(ClockStyle.twentyFourHour.timeString(roundHour, timeZone: tz), "16:00")
        XCTAssertEqual(ClockStyle.twentyFourHour.timeString(withMinutes, timeZone: tz), "16:20")
    }

    func testClockStyleDateBearingFormats() {
        let tz = TimeZone(identifier: "Europe/Amsterdam")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        // A Wednesday, with seconds, so every field of every format is exercised.
        let date = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 16, minute: 4, second: 15))!

        XCTAssertEqual(ClockStyle.twelveHour.preciseTimeString(date, timeZone: tz), "4:04:15pm")
        XCTAssertEqual(ClockStyle.twentyFourHour.preciseTimeString(date, timeZone: tz), "16:04:15")

        XCTAssertEqual(ClockStyle.twelveHour.dayTimeString(date, timeZone: tz), "Wed 4:04pm")
        XCTAssertEqual(ClockStyle.twentyFourHour.dayTimeString(date, timeZone: tz), "Wed 16:04")

        XCTAssertEqual(ClockStyle.twelveHour.dateTimeString(date, timeZone: tz), "Wed 01 Jul 4:04pm")
        XCTAssertEqual(ClockStyle.twentyFourHour.dateTimeString(date, timeZone: tz), "Wed 01 Jul 16:04")
        XCTAssertEqual(
            ClockStyle.twelveHour.dateTimeString(date, timeZone: tz, seconds: true), "Wed 01 Jul 4:04:15pm")
        XCTAssertEqual(
            ClockStyle.twentyFourHour.dateTimeString(date, timeZone: tz, seconds: true), "Wed 01 Jul 16:04:15")

        XCTAssertEqual(ClockStyle.twelveHour.stampString(date, timeZone: tz), "07-01 4:04:15pm")
        XCTAssertEqual(ClockStyle.twentyFourHour.stampString(date, timeZone: tz), "07-01 16:04:15")
    }

    func testClockStyleMinuteAndHourLabels() {
        // Midnight, noon, and hour 24 are where 12-hour conversion goes wrong.
        XCTAssertEqual(ClockStyle.twelveHour.minuteString(0), "12am")
        XCTAssertEqual(ClockStyle.twelveHour.minuteString(300), "5am")
        XCTAssertEqual(ClockStyle.twelveHour.minuteString(750), "12:30pm")
        XCTAssertEqual(ClockStyle.twelveHour.minuteString(1410), "11:30pm")
        XCTAssertEqual(ClockStyle.twelveHour.minuteString(1440), "12am")
        XCTAssertEqual(ClockStyle.twentyFourHour.minuteString(300), "05:00")
        XCTAssertEqual(ClockStyle.twentyFourHour.minuteString(1410), "23:30")
        XCTAssertEqual(ClockStyle.twentyFourHour.minuteString(1440), "24:00")

        XCTAssertEqual(ClockStyle.twelveHour.hourTick(0), "12a")
        XCTAssertEqual(ClockStyle.twelveHour.hourTick(5), "5a")
        XCTAssertEqual(ClockStyle.twelveHour.hourTick(12), "12p")
        XCTAssertEqual(ClockStyle.twelveHour.hourTick(14), "2p")
        XCTAssertEqual(ClockStyle.twelveHour.hourTick(24), "12a")
        XCTAssertEqual(ClockStyle.twentyFourHour.hourTick(9), "09")
        XCTAssertEqual(ClockStyle.twentyFourHour.hourTick(14), "14")
    }

    func testFormatResetHonorsClockStyle() {
        let tz = TimeZone(identifier: "Europe/Amsterdam")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 10))!
        let sameDay = cal.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 18, minute: 20))!
        let otherDay = cal.date(from: DateComponents(year: 2026, month: 6, day: 26, hour: 4))!

        XCTAssertEqual(
            UsageReportRenderer.formatReset(sameDay, now: now, timeZone: tz, clockStyle: .twentyFourHour),
            "Resets 18:20 (in 8h 20m) · Europe/Amsterdam")
        XCTAssertEqual(
            UsageReportRenderer.formatReset(otherDay, now: now, timeZone: tz, clockStyle: .twentyFourHour),
            "Resets Jun 26 at 04:00 (in 18h 0m) · Europe/Amsterdam")
    }

    func testPreferencesStoreRoundTripAndDefault() {
        let url = fm.temporaryDirectory.appendingPathComponent("am-prefs-\(UUID().uuidString).json")
        let store = PreferencesStore(fileURL: url)
        defer { try? fm.removeItem(at: url) }

        // Missing file → defaults (12-hour, system theme).
        XCTAssertEqual(store.load().clockStyle, .twelveHour)
        XCTAssertEqual(store.load().theme, .system)

        store.save(Preferences(clockStyle: .twentyFourHour, theme: .dark))
        XCTAssertEqual(store.load(), Preferences(clockStyle: .twentyFourHour, theme: .dark))

        // A file predating `theme` → the missing field falls back to its default.
        try? #"{"clockStyle":"twentyFourHour"}"#.data(using: .utf8)!.write(to: url)
        XCTAssertEqual(store.load(), Preferences(clockStyle: .twentyFourHour, theme: .system))

        // Corrupt file → defaults, never throws.
        try? "{ not json".data(using: .utf8)!.write(to: url)
        XCTAssertEqual(store.load(), .default)
    }

    // MARK: helpers

    func tempFile(contents: String) -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("am-parse-\(UUID().uuidString).json")
        try? contents.data(using: .utf8)!.write(to: url)
        return url
    }
}
