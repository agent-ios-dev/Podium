import Foundation
import CryptoKit

/// Installs the reviewed Cydia bootstrap and the offline iOS 6 tweak stack.
/// The guest kernel already boots with signing enforcement disabled; no
/// real-device exploit or arbitrary Debian maintainer script is executed.
enum JailbreakBootstrap {
    static let markerPath = "/private/var/lib/podium-addons"

    private static let managedPackageNames: Set<String> = [
        "mobilesubstrate", "com.saurik.substrate.safemode", "preferenceloader",
    ]

    static let substrateLaunchCommand =
        "bsexec .. /usr/bin/cynject 1 /Library/Frameworks/CydiaSubstrate.framework/Libraries/SubstrateLauncher.dylib"
    static let substrateSpringBoardLibrary = "/Library/MobileSubstrate/MobileSubstrate.dylib"
    static let springBoardLaunchDaemonPath = "/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"

    /// The signature follows every bundled payload byte, so a new bootstrap
    /// automatically upgrades the persistent guest volume on its next start.
    static var signature: String? {
        guard let toolURL = Bundle.main.url(forResource: "podium_netd", withExtension: "bin"),
              let toolData = try? Data(contentsOf: toolURL),
              let certificateBundleURL = IOSRootCertificateInstaller.bundledArchiveURL,
              let certificateBundleData = try? Data(contentsOf: certificateBundleURL),
              let bootstrapURL = Bundle.main.url(forResource: "cydia-bootstrap", withExtension: "zip"),
              let bootstrapData = try? Data(contentsOf: bootstrapURL) else { return nil }

        var hasher = SHA256()
        hasher.update(data: toolData)
        hasher.update(data: certificateBundleData)
        hasher.update(data: bootstrapData)
        hasher.update(data: Data("ios6-truststore-seed-v1;ios6-russian-locale-v1;tlsroot-signed-ios5-root-bundle-v1;substrate-springboard-dyld-v1".utf8))
        return "6:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func apply(to builder: RootFilesystemBuilder) throws {
        try IOSRootCertificateInstaller.apply(to: builder)
        guard builder.contains("/Applications/MobileSafari.app/MobileSafari"),
              let url = Bundle.main.url(forResource: "cydia-bootstrap", withExtension: "zip") else { return }

        let archive = try ZipArchiveReader(fileURL: url)
        guard let manifestEntry = archive.entry(named: "manifest.json"),
              let manifest = try JSONSerialization.jsonObject(with: archive.data(for: manifestEntry)) as? [[String: Any]] else {
            throw HFSPlusError.corrupt("Missing or invalid Cydia bootstrap manifest")
        }

        func directory(_ path: String) throws {
            if path == "/" || builder.contains(path) { return }
            let parent = (path as NSString).deletingLastPathComponent
            try directory(parent)
            try builder.addFolder(path, owner: 0, group: 0, mode: 0o755)
        }

        for item in manifest.sorted(by: {
            let lhs = $0["path"] as? String ?? ""
            let rhs = $1["path"] as? String ?? ""
            return lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
        }) {
            guard let path = item["path"] as? String,
                  let type = item["type"] as? String,
                  path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  let modeValue = item["mode"] as? Int,
                  let uidValue = item["uid"] as? Int,
                  let gidValue = item["gid"] as? Int else {
                throw HFSPlusError.corrupt("Invalid Cydia bootstrap manifest entry")
            }
            let resolved = try builder.resolvedPath(path, resolvingFinalComponent: false)
            try directory((resolved as NSString).deletingLastPathComponent)
            let mode = UInt16(modeValue)
            let uid = UInt32(uidValue)
            let gid = UInt32(gidValue)
            let replaceManagedPayload = item["replaceExisting"] as? Bool == true

            if builder.contains(resolved), type != "directory" {
                if resolved == "/private/var/lib/dpkg/status",
                   let entry = archive.entry(named: String(path.dropFirst())) {
                    let existing = String(decoding: try builder.contents(of: resolved), as: UTF8.self)
                    let incoming = String(decoding: try archive.data(for: entry), as: UTF8.self)
                    try builder.replaceContents(of: resolved, with: Array(Self.mergingPackageStatus(existing, incoming).utf8))
                    continue
                }
                if resolved == "/private/etc/launchd.conf",
                   let entry = archive.entry(named: String(path.dropFirst())) {
                    let existing = String(decoding: try builder.contents(of: resolved), as: UTF8.self)
                    let incoming = String(decoding: try archive.data(for: entry), as: UTF8.self)
                    try builder.replaceContents(of: resolved, with: Array(Self.mergingLaunchdConfig(existing, incoming).utf8))
                    continue
                }
                guard replaceManagedPayload else { continue }
                try builder.remove(resolved)
            }

            switch type {
            case "directory":
                if !builder.contains(resolved) { try builder.addFolder(resolved, owner: uid, group: gid, mode: mode) }
            case "symlink":
                guard let target = item["target"] as? String else { throw HFSPlusError.corrupt("Invalid bootstrap symlink") }
                if builder.contains(resolved) { try builder.remove(resolved) }
                try builder.addSymbolicLink(resolved, target: target, owner: uid, group: gid, template: "/private/etc/fstab")
            default:
                guard let entry = archive.entry(named: String(path.dropFirst())) else {
                    throw HFSPlusError.corrupt("Missing bootstrap file: \(path)")
                }
                try builder.addFile(resolved, contents: [UInt8](try archive.data(for: entry)),
                                    template: "/usr/libexec/keybagd", mode: mode)
            }
        }

        // Inject into SpringBoard itself. Running cynject against launchd
        // from launchd.conf caused iOS 6 to restart during early boot.
        if builder.contains(springBoardLaunchDaemonPath) {
            try builder.editPropertyList(springBoardLaunchDaemonPath) { job in
                let variables = (job["EnvironmentVariables"] as? NSMutableDictionary) ?? NSMutableDictionary()
                let current = variables["DYLD_INSERT_LIBRARIES"] as? String ?? ""
                var libraries = current.split(separator: ":").map(String.init)
                if !libraries.contains(substrateSpringBoardLibrary) {
                    libraries.append(substrateSpringBoardLibrary)
                }
                variables["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":")
                job["EnvironmentVariables"] = variables
            }
        }

        // Remove the old launchd injection command from upgraded guest disks,
        // while preserving any unrelated launchd.conf settings.
        if builder.contains("/private/etc/launchd.conf") {
            let existing = String(decoding: try builder.contents(of: "/private/etc/launchd.conf"), as: UTF8.self)
            try builder.replaceContents(of: "/private/etc/launchd.conf",
                                        with: Array(Self.mergingLaunchdConfig(existing, "").utf8))
        }

        try builder.addFile("/.cydia_no_stash", contents: [], template: "/private/etc/fstab")
        if let tool = Bundle.main.url(forResource: "podium_netd", withExtension: "bin") {
            try builder.addFile("/usr/libexec/podium_netd", contents: [UInt8](try Data(contentsOf: tool)),
                                template: "/usr/libexec/keybagd", mode: 0o755)
            let daemon: [String: Any] = [
                "Label": "com.podium.netd",
                "ProgramArguments": ["/usr/libexec/podium_netd"],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ThrottleInterval": 30,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: daemon, format: .binary, options: 0)
            try builder.addFile("/System/Library/LaunchDaemons/com.podium.netd.plist", contents: [UInt8](data),
                                template: "/System/Library/LaunchDaemons/com.apple.mobile.keybagd.plist")
        }
        if let signature {
            try builder.addFile(markerPath, contents: [UInt8](signature.utf8), template: "/private/etc/fstab")
        }
    }

    private static func mergingPackageStatus(_ existing: String, _ incoming: String) -> String {
        func records(_ text: String) -> [String] {
            text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        func packageName(_ record: String) -> String? {
            record.split(separator: "\n").first(where: { $0.hasPrefix("Package: ") })
                .map { String($0.dropFirst("Package: ".count)) }
        }

        let preserved = records(existing).filter { !Self.managedPackageNames.contains(packageName($0) ?? "") }
        var installedNames = Set(preserved.compactMap(packageName))
        var managedNames = Set<String>()
        let additions = records(incoming).filter { record in
            guard let name = packageName(record) else { return false }
            if Self.managedPackageNames.contains(name) { return managedNames.insert(name).inserted }
            return installedNames.insert(name).inserted
        }
        return (preserved + additions).joined(separator: "\n\n") + "\n"
    }

    private static func mergingLaunchdConfig(_ existing: String, _ incoming: String) -> String {
        var lines = existing.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != substrateLaunchCommand }
        var seen = Set(lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        for line in incoming.split(whereSeparator: \.isNewline).map(String.init) {
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized != substrateLaunchCommand,
                  seen.insert(normalized).inserted else { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

}
