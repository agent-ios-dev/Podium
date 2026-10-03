import Foundation
import CryptoKit
import SQLite3

/// Adds the public ISRG Root X1 CA to iOS 6's additional-root TrustStore.
/// This is the same TrustStore record format used by the iOS 5–6 importer in
/// ADVTrustStore; the existing database is retained and only the matching
/// certificate subject is inserted or updated.
enum IOSRootCertificateInstaller {
    static let trustStorePath = "/private/var/Keychains/TrustStore.sqlite3"
    static let certificateResource = "ISRGRootX1.cer"
    private static let expectedSHA256 = "96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6"
    private static let trustSettings = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <array/>
    </plist>
    """.utf8)

    private static var bundledCertificateURL: URL? {
        ([Bundle.main] + Bundle.allBundles + Bundle.allFrameworks)
            .first { $0.url(forResource: "ISRGRootX1", withExtension: "cer") != nil }?
            .url(forResource: "ISRGRootX1", withExtension: "cer")
    }

    enum InstallError: Error, CustomStringConvertible {
        case missingCertificate
        case wrongCertificate
        case invalidCertificate
        case invalidTrustStore(String)
        case sqlite(String)

        var description: String {
            switch self {
            case .missingCertificate: return "The bundled ISRG Root X1 certificate is missing."
            case .wrongCertificate: return "The bundled ISRG Root X1 certificate failed its SHA-256 check."
            case .invalidCertificate: return "The bundled ISRG Root X1 certificate has invalid DER data."
            case .invalidTrustStore(let detail): return "The guest TrustStore database is invalid: \(detail)"
            case .sqlite(let detail): return "Couldn't update the guest TrustStore database: \(detail)"
            }
        }
    }

    /// Applies the certificate to a guest filesystem image. The database is
    /// edited in a temporary file before its bytes replace the HFS+ file.
    @discardableResult
    static func apply(to builder: RootFilesystemBuilder) throws -> Bool {
        guard let certificateURL = bundledCertificateURL else {
            throw InstallError.missingCertificate
        }
        let certificate = try Data(contentsOf: certificateURL)
        guard SHA256.hash(data: certificate).map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else {
            throw InstallError.wrongCertificate
        }
        guard builder.contains(trustStorePath) else {
            throw HFSPlusError.missingPath(trustStorePath)
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-truststore-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: temporary.path + suffix)
            }
        }
        try Data(try builder.contents(of: trustStorePath)).write(to: temporary)
        let changed = try install(certificateDER: certificate, databaseAt: temporary)
        guard changed else { return false }
        try builder.replaceContents(of: trustStorePath, with: [UInt8](try Data(contentsOf: temporary)))
        return true
    }

    /// Testable database operation. Returns false when this exact CA entry
    /// is already present and current.
    @discardableResult
    static func install(certificateDER: Data, databaseAt url: URL) throws -> Bool {
        guard SHA256.hash(data: certificateDER).map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else {
            throw InstallError.wrongCertificate
        }
        let subject = try normalizedSubject(in: [UInt8](certificateDER))
        let hash: String
        let digestSHA1 = Data(Insecure.SHA1.hash(data: certificateDER))
        let digestSHA256 = Data(SHA256.hash(data: certificateDER))

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 returned \(openResult)"
            if let db { sqlite3_close(db) }
            throw InstallError.sqlite(detail)
        }
        defer { sqlite3_close(db) }

        let columns = try tableColumns(in: db)
        guard columns.contains("subj"), columns.contains("tset"), columns.contains("data") else {
            throw InstallError.invalidTrustStore("tsettings is missing required columns")
        }
        if columns.contains("sha256") { hash = "sha256" }
        else if columns.contains("sha1") { hash = "sha1" }
        else { throw InstallError.invalidTrustStore("tsettings has no supported certificate fingerprint column") }

        let digestData = hash == "sha256" ? digestSHA256 : digestSHA1
        let subjectHex = subject.hex
        let query = "SELECT \(hash), tset, data FROM tsettings WHERE subj=X'\(subjectHex)' LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw InstallError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW || step == SQLITE_DONE else { throw InstallError.sqlite(String(cString: sqlite3_errmsg(db))) }
        let exists = step == SQLITE_ROW
        let alreadyCurrent = exists && columnData(statement, 0) == digestData &&
            columnData(statement, 1) == trustSettings && columnData(statement, 2) == certificateDER
        sqlite3_finalize(statement)
        if alreadyCurrent { return false }

        let digest = digestData.hex
        let settingsHex = trustSettings.hex
        let certificateHex = certificateDER.hex
        let sql: String
        if exists {
            sql = "UPDATE tsettings SET \(hash)=X'\(digest)', tset=X'\(settingsHex)', data=X'\(certificateHex)' WHERE subj=X'\(subjectHex)'"
        } else {
            sql = "INSERT INTO tsettings (\(hash), subj, tset, data) VALUES (X'\(digest)', X'\(subjectHex)', X'\(settingsHex)', X'\(certificateHex)')"
        }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE; \(sql); COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw InstallError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return true
    }

    private static func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private static func tableColumns(in db: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(tsettings)", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw InstallError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
        }
        guard !columns.isEmpty else { throw InstallError.invalidTrustStore("tsettings table is missing") }
        return columns
    }

    // TrustStore keys certificates by the certificate's subject with every
    // PrintableString uppercased, matching Apple's historical record format.
    private static func normalizedSubject(in der: [UInt8]) throws -> [UInt8] {
        let certificate = try ASN1Element.read(der, at: 0)
        guard certificate.tag == 0x30 else { throw InstallError.invalidCertificate }
        let certificateChildren = try ASN1Element.children(in: der, range: certificate.content)
        guard let tbs = certificateChildren.first, tbs.tag == 0x30 else { throw InstallError.invalidCertificate }
        let fields = try ASN1Element.children(in: der, range: tbs.content)
        let firstField = fields.first?.tag == 0xa0 ? 1 : 0
        let subjectIndex = firstField + 4
        guard fields.indices.contains(subjectIndex), fields[subjectIndex].tag == 0x30 else {
            throw InstallError.invalidCertificate
        }
        return try normalize(der, element: fields[subjectIndex])
    }

    private static func normalize(_ bytes: [UInt8], element: ASN1Element) throws -> [UInt8] {
        var content: [UInt8]
        if element.tag & 0x20 != 0 {
            content = []
            for child in try ASN1Element.children(in: bytes, range: element.content) {
                content += try normalize(bytes, element: child)
            }
        } else {
            content = Array(bytes[element.content])
            if element.tag == 0x13 { content = content.map { (0x61...0x7a).contains($0) ? $0 - 0x20 : $0 } }
        }
        return [element.tag] + ASN1Element.encodeLength(content.count) + content
    }

    private struct ASN1Element {
        let tag: UInt8
        let content: Range<Int>

        static func read(_ bytes: [UInt8], at offset: Int) throws -> ASN1Element {
            guard bytes.indices.contains(offset + 1) else { throw InstallError.invalidCertificate }
            let tag = bytes[offset]
            guard tag & 0x1f != 0x1f else { throw InstallError.invalidCertificate }
            var cursor = offset + 1
            let firstLength = bytes[cursor]
            cursor += 1
            let length: Int
            if firstLength & 0x80 == 0 { length = Int(firstLength) }
            else {
                let byteCount = Int(firstLength & 0x7f)
                guard byteCount > 0, byteCount <= MemoryLayout<Int>.size, cursor + byteCount <= bytes.count else {
                    throw InstallError.invalidCertificate
                }
                var value = 0
                for byte in bytes[cursor..<(cursor + byteCount)] {
                    let (shifted, overflow1) = value.multipliedReportingOverflow(by: 256)
                    let (next, overflow2) = shifted.addingReportingOverflow(Int(byte))
                    guard !overflow1, !overflow2 else { throw InstallError.invalidCertificate }
                    value = next
                }
                length = value
                cursor += byteCount
            }
            guard length >= 0, cursor <= bytes.count, length <= bytes.count - cursor else {
                throw InstallError.invalidCertificate
            }
            return ASN1Element(tag: tag, content: cursor..<(cursor + length))
        }

        static func children(in bytes: [UInt8], range: Range<Int>) throws -> [ASN1Element] {
            var children: [ASN1Element] = []
            var offset = range.lowerBound
            while offset < range.upperBound {
                let child = try read(bytes, at: offset)
                let end = child.content.upperBound
                guard end <= range.upperBound else { throw InstallError.invalidCertificate }
                children.append(child)
                offset = end
            }
            guard offset == range.upperBound else { throw InstallError.invalidCertificate }
            return children
        }

        static func encodeLength(_ length: Int) -> [UInt8] {
            if length < 0x80 { return [UInt8(length)] }
            var value = length
            var bytes: [UInt8] = []
            while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
    }
}

private extension Collection where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
