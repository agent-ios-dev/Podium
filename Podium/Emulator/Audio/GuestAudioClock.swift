import Foundation

/// Observe the reference kernel driver's requested sample rate without
/// replacing its work. Clock divider registers alone don't identify the
/// external clock frequency on this platform. Each hook checks its code
/// signature before reading the 10B500 function's arguments.
enum GuestAudioClock {
    static func install(on cpu: ARMv7CPU, i2s: S5L8930XI2S) {
        let hooks: [(UInt32, [UInt8], Bool)] = [
            (0x80BB_82AC, [0xF0,0xB5,0x03,0xAF,0x2D,0xE9,0x00,0x0D], false),
            (0x80BB_7C68, [0xF0,0xB5,0x03,0xAF,0x4D,0xF8,0x04,0x8D], true)
        ]
        for (address, expected, fromConfiguration) in hooks {
            cpu.nativeFunctions[address] = { [weak i2s] cpu in
                guard let code = cpu.hostAddress(ofVirtual: address, for: .execute),
                      expected.enumerated().allSatisfy({ code.load(fromByteOffset: $0.offset, as: UInt8.self) == $0.element }) else { return false }
                if fromConfiguration {
                    if let rate = try? cpu.readData(cpu.registers[1] &+ 0x1C, width: 4) { i2s?.configure(sampleRate: Double(rate)) }
                } else {
                    let rate = UInt64(cpu.registers[2]) | UInt64(cpu.registers[3]) << 32
                    i2s?.configure(sampleRate: Double(rate))
                }
                return false
            }
        }
    }
}
