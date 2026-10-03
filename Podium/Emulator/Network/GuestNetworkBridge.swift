import Foundation

final class GuestNetworkBridge {
    private let network = PacketNetwork()
    private let lock = NSLock()
    private var packets: [Data] = []
    private(set) var messages: [String] = []
    init() { network.onReceive = { [weak self] packet in
        guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
        if self.packets.count<256 { self.packets.append(packet) }
    } }
    func stop() { network.stop() }
    func install(on cpu: ARMv7CPU) {
        let previous = cpu.userSupervisorCallFilter
        cpu.userSupervisorCallFilter = { [weak self] c in
            guard c.registers[12]==0x504f444e else { return previous?(c) }
            guard let self, c.registers[2]<=65532 else { return 0 }
            let op=c.registers[0], address=c.registers[1], count=Int(c.registers[2])
            do {
                if op==1 || op==3 {
                    var bytes=[UInt8](); bytes.reserveCapacity(count)
                    for i in 0..<count { bytes.append(UInt8(try c.readData(address &+ UInt32(i),width:1))) }
                    if op==1 { self.network.send(Data(bytes)) }
                    else { let line=String(decoding:bytes,as:UTF8.self); self.lock.lock(); self.messages.append(line); self.lock.unlock(); print("GUESTNET: \(line)") }
                    return UInt32(count)
                }
                if op==2 {
                    self.lock.lock(); let packet=self.packets.first
                    if let packet, packet.count<=count { self.packets.removeFirst() }; self.lock.unlock()
                    guard let packet, packet.count<=count else { return 0 }
                    for (i,b) in packet.enumerated() { try c.writeData(UInt32(b),address &+ UInt32(i),width:1) }
                    return UInt32(packet.count)
                }
            } catch { return 0 }
            return 0
        }
    }
}
