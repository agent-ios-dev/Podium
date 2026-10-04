import XCTest
@testable import Podium

final class S5L8930XI2STests: XCTestCase {
    func testGuestDMAIsPacedAndCompletesAfterFIFOConsumption() throws {
        let memory = FlatPhysicalMemory(length: 0x4000)
        var irq = false
        let dma = S5L8930XCDMA(memory: { memory }, setInterruptLine: { _, asserted in irq = asserted })
        let audio = S5L8930XI2S()
        audio.enableOutputTransport()
        dma.attach(audio, dataRegister: S5L8930XPlatform.i2s0TransmitDMAAddress)
        audio.dmaRequest = { dma.pumpPeripherals() }
        var samples = [Float]()
        audio.onSamples = { samples.append(contentsOf: $0) }
        for (offset, value): (UInt32, UInt32) in [(0,0x120),(4,0x103),(8,0x1000),(12,8192),(0x24,0)] {
            try memory.writeWord32(value, at: 0x100 + offset)
        }
        // Stereo signed 16-bit: left +0.5, right -0.5.
        for offset in stride(from: UInt32(0x1000), to: 0x3000, by: 4) {
            try memory.writeWord32(0xC000_4000, at: offset)
        }
        audio.writeRegister(1, at: 0); audio.writeRegister(2, at: 8)
        let channel: UInt32 = 20 // A4 DMA_I2S0_TX
        let channelBase = channel << 12
        dma.writeRegister(2, at: channelBase + 0x4)
        dma.writeRegister(S5L8930XPlatform.i2s0TransmitDMAAddress, at: channelBase + 0x8)
        dma.writeRegister(8192, at: channelBase + 0xC)
        dma.writeRegister(0x100, at: channelBase + 0x14)
        dma.writeRegister(9, at: channelBase)
        XCTAssertFalse(irq, "Filling the FIFO must not instantly consume an entire audio buffer")
        XCTAssertTrue(samples.isEmpty)
        XCTAssertEqual(dma.readRegister(at: channelBase + 0x10), 0x2000, "MAR must follow bytes accepted by the I2S FIFO")
        XCTAssertEqual(dma.readRegister(at: channelBase + 0xC), 4096, "DBR must report the bytes still outstanding")
        XCTAssertEqual(dma.readRegister(at: channelBase + 0x14), 0x100, "CAR must remain on the descriptor being transferred")

        dma.writeRegister(13, at: channelBase) // pause, preserving interrupt enable
        XCTAssertNotEqual(dma.readRegister(at: channelBase) & (1 << 21), 0)
        dma.writeRegister(9, at: channelBase) // resume this descriptor
        XCTAssertEqual(dma.readRegister(at: channelBase) & (1 << 21), 0)
        audio.advance(toTick: 0); audio.advance(toTick: 24_000)
        XCTAssertEqual(samples.count, 88)
        XCTAssertEqual(dma.readRegister(at: channelBase + 0x10), 0x20B0)
        XCTAssertEqual(dma.readRegister(at: channelBase + 0xC), 3920)
        XCTAssertEqual(Array(samples.prefix(4)), [0.5,-0.5,0.5,-0.5])
        audio.advance(toTick: 2_400_000)
        XCTAssertTrue(irq)
        XCTAssertEqual(samples.count, 4096)
        XCTAssertEqual(dma.readRegister(at: channelBase + 0x10), 0x3000)
        XCTAssertEqual(dma.readRegister(at: channelBase + 0xC), 0)
        XCTAssertEqual(dma.readRegister(at: channelBase + 0x14), 0x120)
        audio.writeRegister(0, at: 8)
        XCTAssertNotEqual(audio.readRegister(at: 0) & S5L8930XI2S.controlChannelIdle, 0)
        let before = samples.count; audio.advance(toTick: 4_800_000)
        XCTAssertEqual(samples.count, before, "Stopped channels must not emit stale audio")
    }
}
