import XCTest
import Darwin
import UIKit
import SwiftUI
@testable import Podium

/// Opt-in integration test. Firmware stays ignored and is never distributed.
final class RealDiskBootTests: XCTestCase {
    func testReferenceFirmwareTrustStoreInventory() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ipsw = repo.appendingPathComponent(".reference-firmware/iPod4,1_6.1.6_10B500_Restore.ipsw")
        guard FileManager.default.fileExists(atPath: ipsw.path) else {
            throw XCTSkip("Real firmware TrustStore inventory requires the reference IPSW.")
        }
        let decrypted = ipsw.deletingPathExtension().appendingPathExtension("truststore-inventory.dmg")
        defer { try? FileManager.default.removeItem(at: decrypted) }
        try RootFilesystemPreparer.decryptRootFilesystem(fromFirmwareAt: ipsw, to: decrypted)
        let volume = try HFSPlusVolume(source: UDIFDiskImage(url: decrypted))
        let builder = try RootFilesystemBuilder(volume: volume)
        let paths = ["/private", "/private/var", "/private/var/Keychains", "/var",
                     "/System/Library/Frameworks/Security.framework", "/System/Library/Keychains"]
        for path in paths {
            if builder.isFolder(at: path) {
                let names = try builder.children(of: path).map(\.name)
                print("TRUSTSTORE INVENTORY \(path): \(names.filter { $0.localizedCaseInsensitiveContains("trust") || $0.localizedCaseInsensitiveContains("keychain") || $0.localizedCaseInsensitiveContains("cert") })")
            } else {
                print("TRUSTSTORE INVENTORY \(path): absent")
            }
        }
        for path in IOSRootCertificateInstaller.supportedTrustStorePaths {
            print("TRUSTSTORE INVENTORY candidate \(path): \(builder.contains(path))")
        }
    }

    func testReferenceFirmwareTrustStoreAndRussianLocale() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ipsw = repo.appendingPathComponent(".reference-firmware/iPod4,1_6.1.6_10B500_Restore.ipsw")
        guard FileManager.default.fileExists(atPath: ipsw.path) else {
            throw XCTSkip("Real firmware TrustStore verification requires the reference IPSW.")
        }
        let decrypted = ipsw.deletingPathExtension().appendingPathExtension("truststore-install.dmg")
        defer { try? FileManager.default.removeItem(at: decrypted) }
        try RootFilesystemPreparer.decryptRootFilesystem(fromFirmwareAt: ipsw, to: decrypted)
        let builder = try RootFilesystemBuilder(volume: HFSPlusVolume(source: UDIFDiskImage(url: decrypted)))
        XCTAssertFalse(builder.contains(IOSRootCertificateInstaller.trustStorePath), "A clean iOS 6.1.6 restore image should not contain the per-user TrustStore yet")
        XCTAssertTrue(try IOSRootCertificateInstaller.apply(to: builder), "Podium must seed the missing iOS 6 TrustStore in a clean restore image")
        XCTAssertTrue(builder.contains(IOSRootCertificateInstaller.trustStorePath))
        XCTAssertFalse(try IOSRootCertificateInstaller.apply(to: builder), "Applying the installer a second time must leave the TrustStore unchanged")

        try IOSLanguageInstaller.apply(to: builder)
        let preferencesData = Data(try builder.contents(of: IOSLanguageInstaller.globalPreferencesPath))
        let preferences = try XCTUnwrap(PropertyListSerialization.propertyList(from: preferencesData, format: nil) as? [String: Any])
        XCTAssertEqual(preferences["AppleLanguages"] as? [String], ["ru", "en"])
        XCTAssertEqual(preferences["AppleLocale"] as? String, "ru_RU")

        let keybagURL = try XCTUnwrap(Bundle.main.url(forResource: "keybag_bootstrap", withExtension: "bin"))
        let capturedStateURL = try XCTUnwrap(Bundle.main.url(forResource: "first_boot_state", withExtension: "plist"))
        let keybagBootstrap = [UInt8](try Data(contentsOf: keybagURL))
        let capturedState = try Data(contentsOf: capturedStateURL)
        let setupBuilder = try RootFilesystemBuilder(volume: HFSPlusVolume(source: UDIFDiskImage(url: decrypted)))
        try RootFilesystemRecipe.apply(to: setupBuilder, keybagBootstrap: keybagBootstrap,
                                       firstBootState: capturedState, skipInitialSetup: false)
        for path in [
            "/private/var/mobile/Library/Preferences/com.apple.purplebuddy.plist",
            "/private/var/mobile/Library/Preferences/ByHost/com.apple.purplebuddy.plist",
            "/private/var/mobile/Library/Preferences/com.apple.keyboard.plist",
        ] {
            XCTAssertFalse(setupBuilder.contains(path), "Manual Setup Assistant mode must not mark setup as finished: \(path)")
        }
    }

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
        let launchdConfigPath = "/private/etc/launchd.conf"
        if installed.contains(launchdConfigPath) { try installed.remove(launchdConfigPath) }
        let preservedLaunchdSetting = "setenv PODIUM_PRESERVED_LAUNCHD_SETTING 1"
        try installed.addFile(launchdConfigPath,
                              contents: Array((preservedLaunchdSetting + "\n").utf8),
                              template: "/private/etc/fstab")

        // Model a volume created by the old release: it has the risky launchd
        // hook and no SpringBoard DYLD setting. Migration must replace the hook
        // without losing user data or unrelated launchd settings.
        try JailbreakBootstrap.apply(to: installed)
        try Self.applySubstrateDyldEnvironment(to: installed, enabled: false)
        let priorReleaseConfig = preservedLaunchdSetting + "\n" + JailbreakBootstrap.substrateLaunchCommand + "\n"
        try installed.replaceContents(of: launchdConfigPath, with: Array(priorReleaseConfig.utf8))
        try installed.replaceContents(of: JailbreakBootstrap.markerPath,
                                      with: Array("5:previous-release-without-substrate-hook".utf8))
        try installed.write(to:image.appendingPathExtension("upgrade-test"),freeSpace:8<<20,maximumVolumeBytes:FileBackedStorage.capacity)
        try FileManager.default.removeItem(at:image)
        try FileManager.default.moveItem(at:image.appendingPathExtension("upgrade-test"),to:image)
        try RootFilesystemPreparer.installGuestAddonsIfNeeded(to:image)
        let upgraded=try RootFilesystemBuilder(volume:HFSPlusVolume(source:FileVolumeSource(url:image)))
        XCTAssertEqual(String(decoding:try upgraded.contents(of:sentinel),as:UTF8.self),"preserve guest data")
        XCTAssertEqual(String(decoding:try upgraded.contents(of:JailbreakBootstrap.markerPath),as:UTF8.self),JailbreakBootstrap.signature)
        for path in ["/Applications/Cydia.app/Cydia", "/usr/libexec/cydia/cydo", "/usr/lib/libapt-pkg.dylib", "/usr/bin/dpkg", "/usr/libexec/podium_netd"] {
            XCTAssertTrue(upgraded.contains(path),"New guest must contain \(path)")
        }
        for path in [
            "/Library/Frameworks/CydiaSubstrate.framework/Libraries/SubstrateLauncher.dylib",
            "/Library/MobileSubstrate/DynamicLibraries/MobileSafety.dylib",
            "/Library/MobileSubstrate/DynamicLibraries/PreferenceLoader.dylib",
        ] {
            XCTAssertTrue(upgraded.contains(path), "The offline tweak bootstrap must install \(path)")
        }
        let packageStatus = String(decoding: try upgraded.contents(of: "/private/var/lib/dpkg/status"), as: UTF8.self)
        for package in ["mobilesubstrate", "com.saurik.substrate.safemode", "preferenceloader"] {
            XCTAssertTrue(packageStatus.contains("Package: \(package)\nStatus: install ok installed"),
                          "dpkg and Cydia must see \(package) as installed")
            XCTAssertTrue(upgraded.contains("/private/var/lib/dpkg/info/\(package).list"),
                          "dpkg must have the file list for \(package)")
        }
        let upgradedLaunchdConfig = String(decoding: try upgraded.contents(of: launchdConfigPath), as: UTF8.self)
        XCTAssertTrue(upgradedLaunchdConfig.contains(preservedLaunchdSetting), "Substrate setup must preserve existing launchd settings")
        XCTAssertFalse(upgradedLaunchdConfig.contains(JailbreakBootstrap.substrateLaunchCommand),
                       "The old cynject hook must be removed during migration")
        var springBoardFormat = PropertyListSerialization.PropertyListFormat.binary
        let springBoardData = Data(try upgraded.contents(of: JailbreakBootstrap.springBoardLaunchDaemonPath))
        let springBoardJob = try XCTUnwrap(PropertyListSerialization.propertyList(from: springBoardData,
            options: .mutableContainersAndLeaves, format: &springBoardFormat) as? [String: Any])
        let springBoardVariables = try XCTUnwrap(springBoardJob["EnvironmentVariables"] as? [String: Any])
        let springBoardLibraries = (springBoardVariables["DYLD_INSERT_LIBRARIES"] as? String ?? "")
            .split(separator: ":").map(String.init)
        XCTAssertTrue(springBoardLibraries.contains(JailbreakBootstrap.substrateSpringBoardLibrary),
                      "The migrated guest must load Substrate into SpringBoard")
        let substrateMode = ProcessInfo.processInfo.environment["PODIUM_TEST_SUBSTRATE_MODE"] ?? "dyld_environment"
        let testSubstrateInjection = substrateMode == "launchd" || substrateMode == "dyld_environment"
        XCTAssertTrue(["baseline", "launchd", "dyld_environment"].contains(substrateMode),
                      "Unknown Substrate boot mode: \(substrateMode)")
        if substrateMode == "baseline" || substrateMode == "launchd" {
            try Self.applySubstrateDyldEnvironment(to: upgraded, enabled: false)
            if substrateMode == "launchd" {
                let current = String(decoding: try upgraded.contents(of: launchdConfigPath), as: UTF8.self)
                try upgraded.replaceContents(of: launchdConfigPath,
                    with: Array((current + JailbreakBootstrap.substrateLaunchCommand + "\n").utf8))
            }
            try Self.writeGuestImage(upgraded, replacing: image)
        }

        let probeURL: URL? = {
            if let url = Bundle(for: RealDiskBootTests.self).url(forResource: "PodiumInjectionProbe", withExtension: "bin") {
                return url
            }
            if let path = ProcessInfo.processInfo.environment["PODIUM_SUBSTRATE_PROBE_PATH"],
               FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return nil
        }()
        if testSubstrateInjection {
            let probe = try XCTUnwrap(probeURL, "Substrate injection requested, but the probe dylib was not built or located.")
            try Self.installSubstrateProbe(probe, into: image)
        }

        let kernel = try KernelcacheExtractor.extractKernelMachO(from: firmware, storedAt: ipsw)
        let tree = try DeviceTreeExtractor.extractDeviceTree(from: firmware, storedAt: ipsw)
        if FileManager.default.fileExists(atPath: ipsw.deletingLastPathComponent().appendingPathComponent("trace-buffer-mapping").path) {
            setenv("PODIUM_DISK_TRACE", "1", 1)
        }
        setenv("PODIUM_NETWORK_TEST", "1", 1)
        defer { unsetenv("PODIUM_DISK_TRACE"); unsetenv("PODIUM_NETWORK_TEST") }
        let audio = GuestAudioCapture()
        let session = try EmulationSession(kernel: kernel, deviceTree: tree, rootFilesystem: image, persistent: true, audioOutput: audio)
        session.platform.i2s0.traceAccess = { print("AUDIOTRACE: \($0)") }
        session.platform.cdma.log = { line in
            if line.contains("peripheral") || line.contains("started") { print("AUDIOTRACE: \(line)") }
        }
        session.start()
        defer { session.stop() }
        var messages = ""
        var lockScreenAppeared = false
        let bootOnly = ProcessInfo.processInfo.environment["PODIUM_TEST_BOOT_ONLY"] == "1"
        var captured = Set<String>()
        var firstSeen = [String:Int]()
        for second in 0..<300 {
            Thread.sleep(forTimeInterval: 1)
            let text = session.newKernelMessages()
            messages += text
            if !text.isEmpty { print("GUEST: \(text)") }
            let snapshot = session.snapshot()
            for (event,name) in [("Safari foreground","safari"),("Cydia foreground","cydia")] {
                if session.guestNetwork.messages.contains(event), firstSeen[name]==nil { firstSeen[name]=second }
                if let appeared=firstSeen[name], second-appeared>=30, !captured.contains(name) {
                    captured.insert(name)
                    let display=session.display, width=display.pixelWidth, height=display.pixelHeight
                    var pixels=Data(count:width*height*4)
                    pixels.withUnsafeMutableBytes { display.copyCurrentFrame(into:$0) }
                    let provider=CGDataProvider(data:pixels as CFData)!
                    let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little),
                        provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
                    let attachment=XCTAttachment(image:UIImage(cgImage:image)); attachment.name="guest-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
                    if name == "cydia" {
                        let guest = UIImage(cgImage: image)
                        let render = {
                            MainActor.assumeIsolated {
                                let view = ClassicIPodCase(width: 300, onEvent: { _ in }) { _ in
                                    Image(uiImage: guest).resizable()
                                }
                                let renderer = ImageRenderer(content: view)
                                renderer.scale = 2
                                return renderer.uiImage
                            }
                        }
                        let preview = Thread.isMainThread ? render() : DispatchQueue.main.sync(execute: render)
                        if let preview {
                            let attachment = XCTAttachment(image: preview)
                            attachment.name = "classic-ipod-case"; attachment.lifetime = .keepAlways; add(attachment)
                        }
                    }
                }
            }
            if second % 5 == 0 { print("BOOTTRACE: t=\(second) instructions=\(snapshot.retiredInstructions) JIT=\(snapshot.jitAvailable) state=\(snapshot.state)") }
            guard snapshot.state == .running else {
                XCTFail("Guest stopped during reference boot: \(snapshot.state); kernel log: \(messages)")
                return
            }
            if EmulatorCore.lockScreenIsUp(session.display) {
                lockScreenAppeared = true
                if bootOnly { break }
                print("BOOTTRACE: lock screen appeared at t=\(second), instructions=\(snapshot.retiredInstructions)")
                let events=session.guestNetwork.messages
                if events.contains("CFNetwork fetched Example Domain") && captured.contains("cydia") && audio.nonzeroSamples > 20_000 { break }
            }
        }
        // The small kernel ring can overwrite early mount messages before
        // the first poll. The disk header and running userland verify boot.
        XCTAssertTrue(lockScreenAppeared, "The real guest must show its lock screen, not merely keep executing kernel code")
        session.stop()
        if testSubstrateInjection {
            let booted = try RootFilesystemBuilder(volume: HFSPlusVolume(source: FileVolumeSource(url: image)))
            let probeMarker = "/private/var/mobile/Library/Preferences/PodiumSubstrateInjectionProbe"
            XCTAssertTrue(booted.contains(probeMarker),
                          "Substrate must load a SpringBoard-filtered tweak and run its constructor")
            XCTAssertEqual(String(decoding: try booted.contents(of: probeMarker), as: UTF8.self),
                           "SpringBoard tweak constructor ran\n")
        }
        if bootOnly { return }
        XCTAssertTrue(session.guestNetwork.messages.contains("utun configured 10.0.2.15 -> 10.0.2.2"), "Guest tunnel must be configured")
        XCTAssertTrue(session.guestNetwork.messages.contains("HTTP test received a real internet response"), "Guest sockets and DNS must reach a real HTTP server: \(session.guestNetwork.messages)")
        XCTAssertTrue(session.guestNetwork.messages.contains("CFNetwork fetched Example Domain"), "Safari's network library must fetch the actual page: \(session.guestNetwork.messages)")
        XCTAssertTrue(session.guestNetwork.messages.contains("Cydia uicache completed"), "Cydia must finish its startup and app registration: \(session.guestNetwork.messages)")
        XCTAssertTrue(session.guestNetwork.messages.contains("Safari foreground"), "Safari must open inside the guest")
        XCTAssertTrue(session.guestNetwork.messages.contains("Cydia foreground"), "Cydia must open inside the guest")
        XCTAssertGreaterThan(audio.nonzeroSamples, 20_000, "Real guest audio playback must deliver non-silent PCM through I2S/DMA")
        print("AUDIOTRACE: captured \(audio.nonzeroSamples) nonzero samples at \(audio.sampleRate) Hz")
        let attachment = XCTAttachment(data: audio.wave(), uniformTypeIdentifier: "com.microsoft.waveform-audio")
        attachment.name = "guest-audio"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private static func installSubstrateProbe(_ probeURL: URL, into image: URL) throws {
        let builder = try RootFilesystemBuilder(volume: HFSPlusVolume(source: FileVolumeSource(url: image)))
        let dylibPath = "/Library/MobileSubstrate/DynamicLibraries/PodiumInjectionProbe.dylib"
        let filterPath = "/Library/MobileSubstrate/DynamicLibraries/PodiumInjectionProbe.plist"
        let filter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Filter</key><dict><key>Bundles</key><array><string>com.apple.springboard</string></array></dict></dict></plist>
        """
        let probeSize = (try FileManager.default.attributesOfItem(atPath: probeURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        try builder.addFile(dylibPath, from: probeURL, length: probeSize, owner: 0, group: 0,
                            mode: 0o755, template: "/usr/libexec/keybagd")
        try builder.addFile(filterPath, contents: Array(filter.utf8), owner: 0, group: 0,
                            mode: 0o644, template: "/private/etc/fstab")
        try writeGuestImage(builder, replacing: image)
    }

    private static func applySubstrateDyldEnvironment(to builder: RootFilesystemBuilder, enabled: Bool) throws {
        let launchDaemonPath = JailbreakBootstrap.springBoardLaunchDaemonPath
        XCTAssertTrue(builder.contains(launchDaemonPath), "iOS 6 must have SpringBoard's launchd job plist")
        try builder.editPropertyList(launchDaemonPath) { job in
            let variables = (job["EnvironmentVariables"] as? NSMutableDictionary) ?? NSMutableDictionary()
            let current = variables["DYLD_INSERT_LIBRARIES"] as? String ?? ""
            var libraries = current.split(separator: ":").map(String.init)
            if enabled {
                if !libraries.contains(JailbreakBootstrap.substrateSpringBoardLibrary) {
                    libraries.append(JailbreakBootstrap.substrateSpringBoardLibrary)
                }
            } else {
                libraries.removeAll { $0 == JailbreakBootstrap.substrateSpringBoardLibrary }
            }
            if libraries.isEmpty {
                variables.removeObject(forKey: "DYLD_INSERT_LIBRARIES")
            } else {
                variables["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":")
            }
            if variables.count == 0 {
                job.removeObject(forKey: "EnvironmentVariables")
            } else {
                job["EnvironmentVariables"] = variables
            }
        }
    }

    private static func writeGuestImage(_ builder: RootFilesystemBuilder, replacing image: URL) throws {
        let staging = image.appendingPathExtension("integration-test")
        defer { try? FileManager.default.removeItem(at: staging) }
        try builder.write(to: staging, freeSpace: 8 << 20, maximumVolumeBytes: FileBackedStorage.capacity)
        try FileManager.default.removeItem(at: image)
        try FileManager.default.moveItem(at: staging, to: image)
    }
}

private final class GuestAudioCapture: AudioOutput {
    var volume: Float = 1
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate: Double = 44_100
    var sampleRate: Double { lock.lock(); defer { lock.unlock() }; return rate }
    var nonzeroSamples: Int { lock.lock(); defer { lock.unlock() }; return samples.filter { abs($0) > 0.00001 }.count }
    func configure(sampleRate: Double) { lock.lock(); rate = sampleRate; lock.unlock() }
    func pause() {}
    func resume() {}
    func enqueue(samples chunk: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard samples.count < 96_000 * 2 * 6 else { return }
        if samples.isEmpty, !chunk.contains(where: { abs($0) > 0.00001 }) { return }
        samples.append(contentsOf: chunk.prefix(96_000 * 2 * 6 - samples.count))
    }
    func wave() -> Data {
        lock.lock(); defer { lock.unlock() }
        var result = Data()
        func word(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        word(0x46464952); word(36 + bytes); word(0x45564157); word(0x20746D66); word(16)
        word(0x00020001); word(UInt32(rate)); word(UInt32(rate) * 4); word(0x00100004); word(0x61746164); word(bytes)
        for sample in samples {
            var value = Int16(max(-32768, min(32767, Int(sample * 32767)))).littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        return result
    }
}
