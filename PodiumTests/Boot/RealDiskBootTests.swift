import XCTest
import Darwin
import UIKit
import SwiftUI
@testable import Podium

/// Opt-in integration test. Firmware stays ignored and is never distributed.
final class RealDiskBootTests: XCTestCase {
    func testReferenceFirmwareTrustStoreInstallation() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ipsw = repo.appendingPathComponent(".reference-firmware/iPod4,1_6.1.6_10B500_Restore.ipsw")
        guard FileManager.default.fileExists(atPath: ipsw.path) else {
            throw XCTSkip("Real firmware TrustStore verification requires the reference IPSW.")
        }
        let keybag = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "keybag_bootstrap", withExtension: "bin")))
        let sync = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "podium_syncd", withExtension: "bin")))
        let state = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "first_boot_state", withExtension: "plist")))
        let readFiles = try String(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "boot_read_files", withExtension: "txt")), encoding: .utf8)
        let image = try RootFilesystemPreparer.prepare(firmwareAt: ipsw, keybagBootstrap: [UInt8](keybag),
            syncDaemon: [UInt8](sync), firstBootState: state, bootReadFiles: RootFilesystemRecipe.fileList(readFiles))
        let builder = try RootFilesystemBuilder(volume: HFSPlusVolume(source: FileVolumeSource(url: image)))
        XCTAssertTrue(IOSRootCertificateInstaller.supportedTrustStorePaths.contains(where: builder.contains), "The reference iOS 6 root filesystem must contain a TrustStore")
        XCTAssertFalse(try IOSRootCertificateInstaller.apply(to: builder), "The prepared TrustStore must already contain the verified ISRG Root X1 record")
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
        try installed.remove(JailbreakBootstrap.markerPath)
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
                print("BOOTTRACE: lock screen appeared at t=\(second), instructions=\(snapshot.retiredInstructions)")
                let events=session.guestNetwork.messages
                if events.contains("CFNetwork fetched Example Domain") && captured.contains("cydia") && audio.nonzeroSamples > 20_000 { break }
            }
        }
        // The small kernel ring can overwrite early mount messages before
        // the first poll. The disk header and running userland verify boot.
        XCTAssertTrue(lockScreenAppeared, "The real guest must show its lock screen, not merely keep executing kernel code")
        XCTAssertTrue(session.guestNetwork.messages.contains("utun configured 10.0.2.15 -> 10.0.2.2"), "Guest tunnel must be configured")
        XCTAssertTrue(session.guestNetwork.messages.contains("HTTP test received a real internet response"), "Guest sockets and DNS must reach a real HTTP server: \(session.guestNetwork.messages)")
        XCTAssertTrue(session.guestNetwork.messages.contains("CFNetwork fetched Example Domain"), "Safari's network library must fetch the actual page: \(session.guestNetwork.messages)")
        XCTAssertTrue(session.guestNetwork.messages.contains("Cydia uicache completed"), "Cydia must finish its startup and app registration: \(session.guestNetwork.messages)")
        XCTAssertTrue(session.guestNetwork.messages.contains("Safari foreground"), "Safari must open inside the guest")
        XCTAssertTrue(session.guestNetwork.messages.contains("Cydia foreground"), "Cydia must open inside the guest")
        session.stop()
        XCTAssertGreaterThan(audio.nonzeroSamples, 20_000, "Real guest audio playback must deliver non-silent PCM through I2S/DMA")
        print("AUDIOTRACE: captured \(audio.nonzeroSamples) nonzero samples at \(audio.sampleRate) Hz")
        let attachment = XCTAttachment(data: audio.wave(), uniformTypeIdentifier: "com.microsoft.waveform-audio")
        attachment.name = "guest-audio"; attachment.lifetime = .keepAlways; add(attachment)
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
