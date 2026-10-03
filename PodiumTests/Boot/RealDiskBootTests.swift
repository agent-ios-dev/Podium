import XCTest
import Darwin
@testable import Podium

/// Opt-in integration test. Firmware stays ignored and is never distributed.
final class RealDiskBootTests: XCTestCase {
    func testReferenceFirmwareBootWithFileBackedDisk() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ipsw = repo.appendingPathComponent(".reference-firmware/iPod4,1_6.1.6_10B500_Restore.ipsw")
        guard FileManager.default.fileExists(atPath: ipsw.path) else {
            throw XCTSkip("Real firmware boot is opt-in; import the reference IPSW first.")
        }
        let parsed = try IPSWParser.parse(fileURL: ipsw)
        let firmware = ImportedFirmware(id: UUID(), metadata: parsed.metadata, compatibility: parsed.compatibility,
                                        importedAt: Date(), storedFileName: ipsw.lastPathComponent, isActive: true)
        let bundle = Bundle.main
        let keybag = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "keybag_bootstrap", withExtension: "bin")))
        let sync = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "podium_syncd", withExtension: "bin")))
        let state = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "first_boot_state", withExtension: "plist")))
        let readFiles = try String(contentsOf: XCTUnwrap(bundle.url(forResource: "boot_read_files", withExtension: "txt")), encoding: .utf8)
        let image = try RootFilesystemPreparer.prepare(firmwareAt: ipsw, keybagBootstrap: [UInt8](keybag),
            syncDaemon: [UInt8](sync), firstBootState: state, bootReadFiles: RootFilesystemRecipe.fileList(readFiles))
        let header = try RootFilesystemPreparer.readHFSPlusVolumeHeader(at: image)
        XCTAssertEqual(UInt64(header.totalBlocks) * UInt64(header.blockSize), FileBackedStorage.capacity)
        let installed=try RootFilesystemBuilder(volume:HFSPlusVolume(source:FileVolumeSource(url:image)))
        let sentinel="/private/var/mobile/Media/podium-upgrade-check.txt"
        try installed.addFile(sentinel,contents:Array("preserve guest data".utf8),template:"/private/etc/fstab")
        try installed.remove(JailbreakBootstrap.markerPath)
        try installed.write(to:image.appendingPathExtension("upgrade-test"),freeSpace:8<<20,maximumVolumeBytes:FileBackedStorage.capacity)
        try FileManager.default.removeItem(at:image)
        try FileManager.default.moveItem(at:image.appendingPathExtension("upgrade-test"),to:image)
        try RootFilesystemPreparer.installGuestAddonsIfNeeded(to:image)
        let upgraded=try RootFilesystemBuilder(volume:HFSPlusVolume(source:FileVolumeSource(url:image)))
        XCTAssertEqual(String(decoding:try upgraded.contents(of:sentinel),as:UTF8.self),"preserve guest data")
        XCTAssertEqual(String(decoding:try upgraded.contents(of:JailbreakBootstrap.markerPath),as:UTF8.self),JailbreakBootstrap.signature)
        for path in ["/Applications/Cydia.app/Cydia", "/usr/libexec/cydia/cydo", "/usr/bin/apt-get", "/usr/bin/dpkg", "/usr/libexec/podium_netd"] {
            XCTAssertTrue(upgraded.contains(path),"New guest must contain \(path)")
        }
        let kernel = try KernelcacheExtractor.extractKernelMachO(from: firmware, storedAt: ipsw)
        let tree = try DeviceTreeExtractor.extractDeviceTree(from: firmware, storedAt: ipsw)
        if FileManager.default.fileExists(atPath: ipsw.deletingLastPathComponent().appendingPathComponent("trace-buffer-mapping").path) {
            setenv("PODIUM_DISK_TRACE", "1", 1)
        }
        setenv("PODIUM_NETWORK_TEST", "1", 1)
        defer { unsetenv("PODIUM_DISK_TRACE"); unsetenv("PODIUM_NETWORK_TEST") }
        let session = try EmulationSession(kernel: kernel, deviceTree: tree, rootFilesystem: image, persistent: true)
        session.start()
        defer { session.stop() }
        var messages = ""
        var lockScreenAppeared = false
        for second in 0..<180 {
            Thread.sleep(forTimeInterval: 1)
            let text = session.newKernelMessages()
            messages += text
            if !text.isEmpty { print("GUEST: \(text)") }
            let snapshot = session.snapshot()
            if second % 5 == 0 { print("BOOTTRACE: t=\(second) instructions=\(snapshot.retiredInstructions) JIT=\(snapshot.jitAvailable) state=\(snapshot.state)") }
            guard snapshot.state == .running else {
                XCTFail("Guest stopped during reference boot: \(snapshot.state); kernel log: \(messages)")
                return
            }
            if EmulatorCore.lockScreenIsUp(session.display) {
                lockScreenAppeared = true
                print("BOOTTRACE: lock screen appeared at t=\(second), instructions=\(snapshot.retiredInstructions)")
                let events=session.guestNetwork.messages
                if events.contains("HTTP test received a real internet response") && events.contains("Cydia uicache completed") { break }
            }
        }
        XCTAssertTrue(messages.contains("BSD root") || messages.contains("hfs:"), "The guest must reach its real disk driver: \(messages)")
        XCTAssertTrue(lockScreenAppeared, "The real guest must show its lock screen, not merely keep executing kernel code")
        XCTAssertTrue(session.guestNetwork.messages.contains("utun configured 10.0.2.15 -> 10.0.2.2"), "Guest tunnel must be configured")
        XCTAssertTrue(session.guestNetwork.messages.contains("HTTP test received a real internet response"), "Guest sockets and DNS must reach a real HTTP server: \(session.guestNetwork.messages)")
        XCTAssertTrue(session.guestNetwork.messages.contains("Cydia uicache completed"), "Cydia must finish its startup and app registration: \(session.guestNetwork.messages)")
    }
}
