import Foundation

/// AppleSamsungI2S's transmit channel. CDMA fills a bounded FIFO; the
/// virtual audio clock drains PCM and lets CDMA complete buffers normally.
final class S5L8930XI2S: MMIODevice, DMAEndpoint {
    static let windowLength: UInt32 = 0xC00
    static let controlChannelIdle: UInt32 = 1 << 1
    static let transmitData: UInt32 = 0x10

    private var registers = [UInt32](repeating: 0, count: Int(windowLength / 4))
    var traceAccess: ((String) -> Void)?
    private var fifo = [UInt8](repeating: 0, count: 4096)
    private var head = 0
    private var count = 0
    private var lastTick: UInt64?
    private var fraction: Double = 0
    private(set) var sampleRate: Double = 44_100
    /// The original firmware path leaves audio MMIO inert. Enable this only
    /// when the user opts into the experimental host-audio bridge.
    private(set) var transportEnabled = false
    var dmaRequest: (() -> Void)?
    var clockChanged: (() -> Void)?
    var onSamples: (([Float]) -> Void)?
    var onFormat: ((Double) -> Void)?
    private var active: Bool { transportEnabled && (registers[0] & 1) != 0 && (registers[2] & 2) != 0 }
    var isActive: Bool { active }
    // Once TX is shut down, the guest may still notify CDMA while tearing
    // down its command ring. Don't let that DMA restart against a stopped port.
    var dmaSpace: Int { transportEnabled && (registers[2] & 2) != 0 ? fifo.count - count : 0 }
    var dmaAvailable: Int { 0 }
    func dmaPop() -> UInt8 { 0 }
    func dmaPush(_ byte: UInt8) {
        guard transportEnabled, registers[2] & 2 != 0, count < fifo.count else { return }
        fifo[(head + count) % fifo.count] = byte; count += 1
    }
    private func pop() -> UInt8 {
        let byte = fifo[head]; head = (head + 1) % fifo.count; count -= 1; return byte
    }
    func configure(sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 96_000 else { return }
        guard self.sampleRate != sampleRate else { return }
        self.sampleRate = sampleRate; fraction = 0; onFormat?(sampleRate)
        traceAccess?("I2S sample rate \(sampleRate)")
    }

    func enableOutputTransport() { transportEnabled = true }

    func readRegister(at offset: UInt32) -> UInt32 {
        let value = registers[Int(offset / 4)]
        return offset == 0 && transportEnabled
            ? (active ? value & ~Self.controlChannelIdle : value | Self.controlChannelIdle)
            : (offset == 0 ? value | Self.controlChannelIdle : value)
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        traceAccess?(String(format: "I2S W %03x = %08x", offset, value))
        if offset == Self.transmitData {
            for shift in stride(from: 0, to: 32, by: 8) { dmaPush(UInt8(truncatingIfNeeded: value >> shift)) }
            return
        }
        registers[Int(offset / 4)] = value
        if offset == 0 || offset == 8 {
            lastTick = nil; fraction = 0
            if offset == 8, value & 2 == 0 { head = 0; count = 0 }
            clockChanged?(); dmaRequest?()
        }
    }
    /// Paced by virtual device time, never host wall time.
    func advance(toTick tick: UInt64) {
        guard active else { lastTick = tick; return }
        guard let last = lastTick else { lastTick = tick; return }
        lastTick = tick
        let elapsed = Double(tick &- min(last, tick)) / 24_000_000
        let exact = min(elapsed, 0.1) * sampleRate + fraction
        let frames = Int(exact); fraction = exact - Double(frames)
        guard frames > 0 else { return }
        let format = registers[1]
        let wide = format & 0x60 != 0
        let channels = format & 0x80 != 0 ? 1 : 2
        let bytesPerFrame = (wide ? 4 : 2) * channels
        var samples = [Float](); samples.reserveCapacity(frames * 2)
        for _ in 0..<frames {
            if count < bytesPerFrame { dmaRequest?() }
            guard count >= bytesPerFrame else { break }
            func sample() -> Float {
                var raw = UInt32(pop()) | UInt32(pop()) << 8
                if wide {
                    raw |= UInt32(pop()) << 16 | UInt32(pop()) << 24
                    let bits = format & 0x40 != 0 ? 24 : 20
                    let value = Int32(bitPattern: raw << (32 - bits)) >> (32 - bits)
                    return Float(value) / Float(1 << (bits - 1))
                }
                return Float(Int16(bitPattern: UInt16(raw))) / 32768
            }
            let left = sample(), right = channels == 2 ? sample() : left
            samples.append(left); samples.append(right)
        }
        if !samples.isEmpty { onSamples?(samples) }
        dmaRequest?()
    }
}
