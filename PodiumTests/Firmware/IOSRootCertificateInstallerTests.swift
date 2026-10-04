import XCTest
import SQLite3
@testable import Podium

final class IOSRootCertificateInstallerTests: XCTestCase {
    func testInstallsEveryPinnedTLSRootAndIsIdempotent() throws {
        let bundle = Bundle(for: TestBundleToken.self)
        let archiveURL = try XCTUnwrap(bundle.url(forResource: "tlsroot-root-certificates", withExtension: "zip"))
        let archive = try ZipArchiveReader(fileURL: archiveURL)
        let manifestEntry = try XCTUnwrap(archive.entry(named: "manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: archive.data(for: manifestEntry)) as? [String: Any])
        let certificates = try XCTUnwrap(manifest["certificates"] as? [[String: String]])
        XCTAssertEqual(certificates.count, IOSRootCertificateInstaller.expectedCertificateCount)

        let database = FileManager.default.temporaryDirectory.appendingPathComponent("PodiumTLSRoots-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE tsettings(sha1 BLOB NOT NULL DEFAULT '', subj BLOB NOT NULL DEFAULT '', tset BLOB, data BLOB, PRIMARY KEY(sha1));", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)

        for item in certificates {
            let path = try XCTUnwrap(item["path"])
            let expectedSHA256 = try XCTUnwrap(item["sha256"])
            let entry = try XCTUnwrap(archive.entry(named: path))
            XCTAssertTrue(try IOSRootCertificateInstaller.install(certificateDER: archive.data(for: entry),
                                                                   expectedSHA256: expectedSHA256, databaseAt: database))
        }
        XCTAssertEqual(try integer("SELECT COUNT(*) FROM tsettings", in: database), certificates.count)

        for item in certificates {
            let path = try XCTUnwrap(item["path"])
            let expectedSHA256 = try XCTUnwrap(item["sha256"])
            let entry = try XCTUnwrap(archive.entry(named: path))
            XCTAssertFalse(try IOSRootCertificateInstaller.install(certificateDER: archive.data(for: entry),
                                                                    expectedSHA256: expectedSHA256, databaseAt: database))
        }
        XCTAssertEqual(try integer("SELECT COUNT(*) FROM tsettings", in: database), certificates.count)
    }

    func testAddsCertificateToFreshIOS6TrustStoreSchema() throws {
        let certificateURL = try XCTUnwrap(Bundle(for: TestBundleToken.self).url(forResource: "ISRGRootX1", withExtension: "cer"))
        let certificate = try Data(contentsOf: certificateURL)
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("PodiumFreshTrustStore-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        let schema = "CREATE TABLE tsettings(sha1 BLOB NOT NULL DEFAULT '', subj BLOB NOT NULL DEFAULT '', tset BLOB, data BLOB, PRIMARY KEY(sha1));"
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)

        XCTAssertTrue(try IOSRootCertificateInstaller.install(certificateDER: certificate, databaseAt: database))
        XCTAssertFalse(try IOSRootCertificateInstaller.install(certificateDER: certificate, databaseAt: database))
        XCTAssertEqual(try integer("SELECT COUNT(*) FROM tsettings", in: database), 1)
        XCTAssertEqual(try integer("SELECT COUNT(*) FROM tsettings WHERE data=X'\(certificate.map { String(format: "%02x", $0) }.joined())'", in: database), 1)
    }

    func testAddsISRGRootX1ToBothSupportedTrustStoreSchemasAndPreservesExistingEntries() throws {
        let certificateURL = try XCTUnwrap(Bundle(for: TestBundleToken.self).url(forResource: "ISRGRootX1", withExtension: "cer"))
        let certificate = try Data(contentsOf: certificateURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PodiumTrustStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for fingerprintColumn in ["sha1", "sha256"] {
            let database = directory.appendingPathComponent("\(fingerprintColumn).sqlite3")
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
            let db = try XCTUnwrap(connection)
            let schema = "CREATE TABLE tsettings (\(fingerprintColumn) BLOB NOT NULL, subj BLOB NOT NULL UNIQUE, tset BLOB NOT NULL, data BLOB NOT NULL); INSERT INTO tsettings VALUES (X'00', X'0102', X'03', X'04');"
            XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_close(db), SQLITE_OK)

            XCTAssertTrue(try IOSRootCertificateInstaller.install(certificateDER: certificate, databaseAt: database))
            XCTAssertFalse(try IOSRootCertificateInstaller.install(certificateDER: certificate, databaseAt: database))
            XCTAssertEqual(try integer("SELECT COUNT(*) FROM tsettings", in: database), 2)
            XCTAssertEqual(try integer("SELECT COUNT(*) FROM tsettings WHERE subj=X'0102' AND data=X'04'", in: database), 1)
            XCTAssertEqual(try integer("SELECT length(\(fingerprintColumn)) FROM tsettings WHERE data=X'\(certificate.map { String(format: "%02x", $0) }.joined())'", in: database), fingerprintColumn == "sha1" ? 20 : 32)
        }
    }

    private func integer(_ sql: String, in database: URL) throws -> Int {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        return Int(sqlite3_column_int64(query, 0))
    }
}

private final class TestBundleToken: NSObject {}
