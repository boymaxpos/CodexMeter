import Foundation
import SQLite3
import XCTest
@testable import CodexMeterCore

final class HistoryBackupTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seed(_ store: UsageHistoryStore, account: String, used: Int = 20) async throws {
        try await store.recordQuotaSnapshots([
            .init(id: "codex", name: "Weekly", usedPercent: used,
                  windowDurationMins: 10_080, resetsAt: Date().addingTimeInterval(600))
        ], at: Date(), isStale: false, source: .refresh, accountKey: account)
        try await store.recordTokenUsage(.init(
            dailyBuckets: [.init(startDate: "2026-08-01", tokens: 12345)],
            summary: .init(lifetimeTokens: 12345, peakDailyTokens: 12345,
                currentStreakDays: 1, longestStreakDays: 2, longestRunningTurnSeconds: 30), fetchedAt: Date()
        ), accountKey: account)
    }

    func testWALSnapshotRestoresAllAccountsAndPreservesRecoveryBackup() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try UsageHistoryStore(databaseURL: dir.appendingPathComponent("source.sqlite"))
        let salt = "source-salt"
        let a = HistoryAccountIdentity.make(accountType: "chatgpt", email: "a@example.test", salt: salt).key
        let b = HistoryAccountIdentity.make(accountType: "chatgpt", email: "b@example.test", salt: salt).key
        try await seed(source, account: a)
        try await seed(source, account: b, used: 65)
        let export = dir.appendingPathComponent("test.codexmeterbackup")
        try await source.exportBackup(identitySalt: salt, appVersion: "test").write(to: export)
        let archive = try HistoryBackup.read(from: export)
        XCTAssertEqual(archive.manifest.rowCounts["quota_samples"], 2)
        XCTAssertEqual(archive.manifest.rowCounts["token_daily"], 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("source.sqlite-wal").path))
        let targetURL = dir.appendingPathComponent("target.sqlite")
        let target = try UsageHistoryStore(databaseURL: targetURL)
        try await seed(target, account: "old-account")
        let recovery = try await target.restoreBackup(from: export, identitySalt: "old-salt", appVersion: "test") {
            XCTAssertEqual($0, salt)
        }
        XCTAssertEqual(try HistoryBackup.read(from: recovery).manifest.identitySalt, "old-salt")
        let reopened = try UsageHistoryStore(databaseURL: targetURL)
        let rowsA = try await reopened.quotaSamples(since: .distantPast, accountKey: a)
        let rowsB = try await reopened.quotaSamples(since: .distantPast, accountKey: b)
        let old = try await reopened.quotaSamples(since: .distantPast, accountKey: "old-account")
        let tokens = try await reopened.tokenUsage(accountKey: b)
        XCTAssertEqual(rowsA.map(\.remainingPercent), [80])
        XCTAssertEqual(rowsB.map(\.remainingPercent), [35])
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(tokens?.dailyBuckets?.first?.tokens, 12345)
        do { try await seed(target, account: "old-account"); XCTFail("Old process must stop writing") }
        catch { }
    }

    func testSaltFailureRollsBackDatabaseAndSalt() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try UsageHistoryStore(databaseURL: dir.appendingPathComponent("source.sqlite"))
        try await seed(source, account: "new-account")
        let url = dir.appendingPathComponent("test.codexmeterbackup")
        try await source.exportBackup(identitySalt: "new", appVersion: "test").write(to: url)
        let target = try UsageHistoryStore(databaseURL: dir.appendingPathComponent("target.sqlite"))
        try await seed(target, account: "old-account", used: 42)
        do {
            _ = try await target.restoreBackup(from: url, identitySalt: "old", appVersion: "test") {
                if $0 == "new" { throw HistoryBackupError.storageFailure }
                XCTAssertEqual($0, "old")
            }
            XCTFail("Expected injected failure")
        } catch { XCTAssertEqual(error as? HistoryBackupError, .storageFailure) }
        let old = try await target.quotaSamples(since: .distantPast, accountKey: "old-account")
        let new = try await target.quotaSamples(since: .distantPast, accountKey: "new-account")
        XCTAssertEqual(old.map(\.remainingPercent), [58])
        XCTAssertTrue(new.isEmpty)
    }

    func testCorruptAndFutureArchivesDoNotReplaceExistingHistory() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try UsageHistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite"))
        try await seed(store, account: "old")
        let data = try await store.exportBackup(identitySalt: "salt", appVersion: "test")
        let original = try PropertyListDecoder().decode(HistoryBackup.self, from: data)
        let m = original.manifest
        let future = HistoryBackup(manifest: .init(formatVersion: 99, schemaVersion: m.schemaVersion,
            createdAt: m.createdAt, appVersion: m.appVersion, identitySalt: m.identitySalt,
            checksum: m.checksum, rowCounts: m.rowCounts), database: original.database)
        let corrupt = HistoryBackup(manifest: m, database: original.database + Data([1]))
        for bad in [Data("invalid".utf8), try future.encoded(), try corrupt.encoded()] {
            let url = dir.appendingPathComponent("bad.codexmeterbackup")
            try bad.write(to: url)
            do {
                _ = try await store.restoreBackup(from: url, identitySalt: "salt", appVersion: "test") { _ in
                    XCTFail("Must not change identity")
                }
                XCTFail("Must reject invalid archive")
            } catch { }
        }
        let rows = try await store.quotaSamples(since: .distantPast, accountKey: "old")
        XCTAssertEqual(rows.count, 1)
    }

    func testInterruptedRestoreRecoversPreviousDatabaseBeforeAccountActivation() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite")
        let store = try UsageHistoryStore(databaseURL: url)
        try await seed(store, account: "original")
        let archive = try await store.exportBackup(identitySalt: "original-salt", appVersion: "test")
        try await store.clearAll()
        try archive.write(to: HistoryBackup.journalURL(for: url))
        try HistoryBackup.recoverInterruptedRestore(databaseURL: url) { XCTAssertEqual($0, "original-salt") }
        let rows = try await store.quotaSamples(since: .distantPast, accountKey: "original")
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HistoryBackup.journalURL(for: url).path))
    }

    func testSchemaFourBackupMigratesOnFreshMac() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try UsageHistoryStore(databaseURL: dir.appendingPathComponent("source.sqlite"))
        try await seed(source, account: "account")
        let encoded = try await source.exportBackup(identitySalt: "salt", appVersion: "test")
        let original = try PropertyListDecoder().decode(HistoryBackup.self, from: encoded)
        let snapshotURL = dir.appendingPathComponent("schema4.sqlite")
        try original.database.write(to: snapshotURL)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(snapshotURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=4;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let data = try Data(contentsOf: snapshotURL)
        let archive = HistoryBackup(manifest: .init(formatVersion: 1, schemaVersion: 4,
            createdAt: Date(), appVersion: "old", identitySalt: "salt",
            checksum: HistoryBackup.checksum(data), rowCounts: original.manifest.rowCounts), database: data)
        let url = dir.appendingPathComponent("old.codexmeterbackup")
        try archive.encoded().write(to: url)
        let destinationURL = dir.appendingPathComponent("fresh.sqlite")
        let destination = try UsageHistoryStore(databaseURL: destinationURL)
        _ = try await destination.restoreBackup(from: url, identitySalt: "fresh", appVersion: "test") { _ in }
        let reopened = try UsageHistoryStore(databaseURL: destinationURL)
        let restored = try await reopened.quotaSamples(since: .distantPast, accountKey: "account")
        XCTAssertEqual(restored.count, 1)
        let reexport = try await reopened.exportBackup(identitySalt: "salt", appVersion: "test")
        XCTAssertEqual(try PropertyListDecoder().decode(HistoryBackup.self, from: reexport).manifest.schemaVersion, 5)
    }
}
