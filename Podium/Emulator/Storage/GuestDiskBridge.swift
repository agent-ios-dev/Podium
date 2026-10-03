import Foundation
import CryptoKit
import Darwin

/// File-backed md0 for the exact iPod4,1 / 10B500 kernel. Small guest
/// shims still call XNU's buf_map/unmap and biodone, so its buffer cache,
/// VM mappings, scheduling, HFS driver and journal remain in charge.
/// Replacing only bcopy is insufficient: memdev.c truncates offsets and
/// capacity to 32 bits before copying. No eight-GiB guest mapping exists.
enum GuestDiskBridge {
    static let strategyAddress: UInt32 = 0x8009_76BC
    static let rawAddress: UInt32 = 0x8009_7474
    static let transferAddress: UInt32 = 0x8009_7918
    static let ioctlAddress: UInt32 = 0x8009_750C
    static let md0: UInt32 = 0x8032_B008
    static let kernelSHA256 = "415717e559c48fcf8a2aedec05d3ed2efa6312b11de942acd1c56629b72192ef"

    struct UnsupportedKernel: FriendlyError {
        var userMessage: String { "The 8 GiB disk requires the original iPod touch 4 iOS 6.1.6 firmware." }
        var developerDetail: String { "Kernel SHA-256 does not match the verified 10B500 storage ABI." }
    }

    static func patch(_ original: Data) throws -> Data {
        let digest = SHA256.hash(data: original).hexEncodedString
        guard digest == kernelSHA256 else { throw UnsupportedKernel() }
        var kernel = original
        // In this verified Mach-O __TEXT vmaddr/fileoff are 0x80001000/0.
        func put(_ hex: String, at address: UInt32) {
            let bytes = Data(hex: hex)
            let offset = Int(address - 0x8000_1000)
            kernel.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        put(strategyCode, at: strategyAddress)
        put(rawCode, at: rawAddress)
        put("7047", at: transferAddress) // bx lr; native handler supplies the result
        return kernel
    }

    static func install(on cpu: ARMv7CPU, disk: FileBackedStorage) {
        cpu.nativeFunctions[transferAddress] = { cpu in transfer(cpu, disk: disk); return true }
        cpu.nativeFunctions[ioctlAddress] = { cpu in
            // Other md devices and all unrelated ioctls retain XNU behavior.
            guard cpu.registers[0] & 0x00FF_FFFF == 0 else { return false }
            let command = cpu.registers[1], output = cpu.registers[2]
            guard command == 0x4008_6419 || command == 0x4004_6419 || command == 0x2000_6416 else { return false }
            do {
                if command == 0x2000_6416 {
                    try disk.synchronize()
                } else {
                    let sector = try cpu.readData(md0 + 16, width: 4)
                    guard sector >= 512 else { throw FileBackedStorage.IOError(code: EINVAL) }
                    let blocks = (disk.byteCount + UInt64(sector) - 1) / UInt64(sector)
                    guard command == 0x4008_6419 || blocks <= UInt64(UInt32.max) else { throw FileBackedStorage.IOError(code: EOVERFLOW) }
                    try cpu.writeData(UInt32(truncatingIfNeeded: blocks), output, width: 4)
                    if command == 0x4008_6419 { try cpu.writeData(UInt32(blocks >> 32), output + 4, width: 4) }
                }
                cpu.registers[0] = 0
            } catch let error as FileBackedStorage.IOError {
                cpu.registers[0] = UInt32(error.code)
            } catch { cpu.registers[0] = UInt32(EFAULT) }
            return true
        }
    }

    /// Shim ABI: r0=mapped buffer, r1=count, r2:r3=64-bit block index;
    /// stack[0]=buf_flags, stack[4]=dev. Returns r0=errno, r1=bytes done.
    /// Page mappings are checked before touching storage. Each host allocation
    /// is at most one guest page, regardless of the disk's logical size.
    static func transfer(_ cpu: ARMv7CPU, disk: FileBackedStorage) {
        let buffer = cpu.registers[0], requested = Int(cpu.registers[1])
        let block = UInt64(cpu.registers[2]) | UInt64(cpu.registers[3]) << 32
        var done = 0
        defer { cpu.registers[1] = UInt32(done) }
        do {
            let flags = try cpu.readData(cpu.registers.sp, width: 4)
            let device = try cpu.readData(cpu.registers.sp + 4, width: 4)
            guard device & 0x00FF_FFFF == 0 else { throw FileBackedStorage.IOError(code: ENXIO) }
            let sector = try cpu.readData(md0 + 16, width: 4)
            let (offset, overflow) = block.multipliedReportingOverflow(by: UInt64(sector))
            guard sector >= 512, !overflow, offset <= disk.byteCount, requested <= 16 << 20 else {
                throw FileBackedStorage.IOError(code: EINVAL)
            }
            // EOF returns a full residual; requests straddling EOF are short I/O.
            let count = Int(min(UInt64(requested), disk.byteCount - offset))
            guard UInt64(buffer) + UInt64(count) <= UInt64(UInt32.max) + 1 else { throw FileBackedStorage.IOError(code: EFAULT) }
            let reading = flags & 1 != 0 // B_READ
            var pages: [(pointer: UnsafeMutableRawPointer, count: Int)] = []
            var checked = 0
            while checked < count {
                let address = buffer + UInt32(checked)
                let length = min(4096 - Int(address & 4095), count - checked)
                guard let pointer = cpu.hostAddress(ofVirtual: address, for: reading ? .write : .read) else { throw FileBackedStorage.IOError(code: EFAULT) }
                pages.append((pointer, length))
                checked += length
            }
            for page in pages {
                if reading {
                    let data = try disk.read(at: offset + UInt64(done), count: page.count)
                    data.withUnsafeBytes { page.pointer.copyMemory(from: $0.baseAddress!, byteCount: page.count) }
                } else {
                    try disk.write(Data(bytes: page.pointer, count: page.count), at: offset + UInt64(done))
                }
                done += page.count
            }
            cpu.registers[0] = 0
        } catch let error as FileBackedStorage.IOError {
            cpu.registers[0] = UInt32(error.code)
        } catch { cpu.registers[0] = UInt32(EFAULT) }
    }

    // Reproducible shims and annotated disassembly are in StorageBridge/.
    private static let strategyCode = "f0b585b0044605f099fb05460146204605f09efb204602a905f088fd00281cd1204605f05ffd0190204605f071fb0090204605f043fd02460b460298294600f00df903900491204605f094fd0499691a204605f07dfb039900e00e21002902d0204605f037fb204605f056ff05b0f0bd"
    private static let rawCode = "20f07f43002b01d0062070472de9f04184b004460d4628464bf1d6fa80f0010347f2bd60c8f209000021224649f61546c8f21d06009601954bf20806c8f232063669029642f1c6fa04b0bde8f081"
}
