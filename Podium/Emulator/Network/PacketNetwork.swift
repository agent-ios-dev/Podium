import Foundation
import Network
import Darwin

/// IPv4 user-mode NAT for the guest utun interface. Host sockets remain
/// outbound only; no listener or system VPN entitlement is involved.
final class PacketNetwork: NetworkInterface {
    var onReceive: ((Data) -> Void)?
    private let queue = DispatchQueue(label: "Podium.guest-network")
    private var flows: [String: Flow] = [:]
    private var closed = false
    private final class Flow {
        let connection: NWConnection
        let source: [UInt8], destination: [UInt8]
        let sourcePort: UInt16, destinationPort: UInt16
        var next: UInt32 = 0x504f4400
        var expected: UInt32
        var ready = false
        var established = false
        var pending: [(UInt32, Data, Date)] = []
        var buffered = Data()
        var ended = false
        var sentFIN = false
        var reading = false
        var lastActivity = Date()
        init(_ c: NWConnection, _ s: [UInt8], _ d: [UInt8], _ sp: UInt16, _ dp: UInt16, _ seq: UInt32) {
            connection=c; source=s; destination=d; sourcePort=sp; destinationPort=dp; expected=seq &+ 1
        }
    }
    func stop() { queue.async { self.closed=true; self.flows.values.forEach { $0.connection.cancel() }; self.flows.removeAll() } }
    func send(_ packet: Data) { queue.async { if !self.closed { self.consume([UInt8](packet)) } } }
    private func consume(_ p: [UInt8]) {
        guard p.count >= 20, p[0] >> 4 == 4 else { return }
        let h=Int(p[0] & 15)*4, size=Int(Self.u16(p,2))
        guard h>=20, size<=p.count, size>=h+8, Self.u16(p,6)&0x3fff==0 else { return }
        let s=Array(p[12..<16]), d=Array(p[16..<20]), sp=Self.u16(p,h), dp=Self.u16(p,h+2)
        if p[9]==17 {
            guard Int(Self.u16(p,h+4))>=8, h+Int(Self.u16(p,h+4))<=size else { return }
            let body=Array(p[(h+8)..<(h+Int(Self.u16(p,h+4)))])
            if dp==53 { dns(body,s,d,sp,dp); return }
            let c=NWConnection(host: NWEndpoint.Host(d.map(String.init).joined(separator:".")), port: NWEndpoint.Port(rawValue:dp)!, using:.udp)
            c.stateUpdateHandler = { state in if case .ready=state { c.send(content:Data(body),completion:.contentProcessed { _ in }); c.receiveMessage { data,_,_,_ in if let data { self.udp([UInt8](data),s,d,sp,dp) }; c.cancel() } } }
            c.start(queue:queue); queue.asyncAfter(deadline:.now()+15) { c.cancel() }; return
        }
        guard p[9]==6, size>=h+20 else { return }
        let th=Int(p[h+12]>>4)*4
        guard th>=20, h+th<=size, dp != 0 else { return }
        let seq=Self.u32(p,h+4), ack=Self.u32(p,h+8), flags=p[h+13]
        let key="\(s)-\(sp)-\(d)-\(dp)"
        if flags&4 != 0 { flows.removeValue(forKey:key)?.connection.cancel(); return }
        if flows[key]==nil, flags&2 != 0 {
            guard flows.count<128 else { return }
            let c=NWConnection(host:NWEndpoint.Host(d.map(String.init).joined(separator:".")),port:NWEndpoint.Port(rawValue:dp)!,using:.tcp)
            let f=Flow(c,s,d,sp,dp,seq); flows[key]=f
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: f.ready=true; self.tcp(f,flags:0x12); self.retransmit(f,key:key)
                case .failed: self.tcp(f,flags:0x14,remember:false); self.flows.removeValue(forKey:key); c.cancel()
                default: break
                }
            }
            c.start(queue:queue); return
        }
        guard let f=flows[key], f.ready else { return }
        f.lastActivity=Date()
        if flags&0x10 != 0 {
            f.pending.removeAll { Int32(bitPattern:ack &- $0.0)>=0 }
            if !f.established && ack==f.next { f.established=true; receive(f) }
        }
        let body=Data(p[(h+th)..<size])
        if !body.isEmpty {
            if seq==f.expected {
                f.expected &+= UInt32(body.count)
                f.connection.send(content:body,completion:.contentProcessed { error in if error != nil { self.tcp(f,flags:0x14,remember:false) } })
            }
            tcp(f,flags:0x10,remember:false)
        }
        if flags&1 != 0, seq &+ UInt32(body.count)==f.expected {
            f.expected &+= 1; tcp(f,flags:0x10,remember:false)
            f.connection.send(content:nil,contentContext:.finalMessage,isComplete:true,completion:.contentProcessed { _ in })
        }
        flush(f)
    }
    private func receive(_ f: Flow) {
        guard !f.reading, !f.ended, f.buffered.count<65536 else { return }
        f.reading=true
        f.connection.receive(minimumIncompleteLength:1,maximumLength:32768) { data,_,done,error in
            f.reading=false
            if let data { f.buffered.append(data) }; f.ended=done || error != nil; self.flush(f)
            if !f.ended { self.receive(f) }
        }
    }
    private func flush(_ f: Flow) {
        guard f.established else { return }
        while !f.buffered.isEmpty && f.pending.count<8 {
            let n=min(1200,f.buffered.count), part=Data(f.buffered.prefix(n)); f.buffered.removeFirst(n)
            tcp(f,flags:0x18,body:part)
        }
        if f.ended && f.buffered.isEmpty && !f.sentFIN {
            f.sentFIN=true; tcp(f,flags:0x11)
        }
        receive(f)
    }
    private func retransmit(_ f: Flow,key: String) {
        queue.asyncAfter(deadline:.now()+1) {
            guard self.flows[key] === f, !self.closed else { return }
            if Date().timeIntervalSince(f.lastActivity)>120 { f.connection.cancel(); self.flows.removeValue(forKey:key); return }
            for (_,p,date) in f.pending where Date().timeIntervalSince(date)>=1 { self.onReceive?(p) }
            self.retransmit(f,key:key)
        }
    }
    private func tcp(_ f: Flow,flags: UInt8,body: Data=Data(),remember: Bool=true) {
        var t=[UInt8](repeating:0,count:20); Self.put16(&t,0,f.destinationPort); Self.put16(&t,2,f.sourcePort)
        Self.put32(&t,4,f.next); Self.put32(&t,8,f.expected); t[12]=0x50; t[13]=flags; Self.put16(&t,14,32768); t += body
        let p=ip(t,proto:6,source:f.destination,destination:f.source)
        f.next &+= UInt32(body.count)+(flags&2 != 0 ? 1:0)+(flags&1 != 0 ? 1:0)
        if remember && (flags&3 != 0 || !body.isEmpty) { f.pending.append((f.next,p,Date())) }
        onReceive?(p)
    }
    private func udp(_ body: [UInt8],_ s: [UInt8],_ d: [UInt8],_ sp: UInt16,_ dp: UInt16) {
        guard body.count<65000 else { return }; var t=[UInt8](repeating:0,count:8)
        Self.put16(&t,0,dp); Self.put16(&t,2,sp); Self.put16(&t,4,UInt16(body.count+8)); t += body
        onReceive?(ip(t,proto:17,source:d,destination:s))
    }
    private func dns(_ q: [UInt8],_ s: [UInt8],_ d: [UInt8],_ sp: UInt16,_ dp: UInt16) {
        guard q.count>=17, Self.u16(q,4)==1 else { return }; var i=12; var labels=[String]()
        while i<q.count && q[i]>0 {
            let n=Int(q[i]); guard n<=63, i+n+1<=q.count else { return }
            labels.append(String(decoding:q[(i+1)..<(i+1+n)],as:UTF8.self)); i += n+1
        }
        guard i+5<=q.count else { return }; let type=Self.u16(q,i+1)
        var response=Array(q.prefix(i+5)); response[2]=0x81; response[3]=0x80
        Self.put16(&response,6,0); Self.put16(&response,8,0); Self.put16(&response,10,0)
        if type==1 {
            var hints=addrinfo(); hints.ai_family=AF_INET; hints.ai_socktype=SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(labels.joined(separator:"."),nil,&hints,&result)==0, let result {
                defer { freeaddrinfo(result) }
                let a=UnsafeRawPointer(result.pointee.ai_addr!).assumingMemoryBound(to:sockaddr_in.self).pointee.sin_addr
                var raw=a.s_addr; let bytes=withUnsafeBytes(of:&raw) { Array($0) }
                response += [0xc0,0x0c,0,1,0,1,0,0,0,60,0,4]+bytes; Self.put16(&response,6,1)
            } else { response[3]=0x83 }
        }
        udp(response,s,d,sp,dp)
    }
    private func ip(_ payload: [UInt8],proto: UInt8,source: [UInt8],destination: [UInt8]) -> Data {
        var t=payload; let pseudo=source+destination+[0,proto,UInt8(t.count>>8),UInt8(t.count&255)]
        Self.put16(&t,proto==6 ? 16:6,Self.checksum(pseudo+t))
        var h=[UInt8](repeating:0,count:20); h[0]=0x45; h[8]=64; h[9]=proto
        Self.put16(&h,2,UInt16(t.count+20)); h.replaceSubrange(12..<16,with:source); h.replaceSubrange(16..<20,with:destination)
        Self.put16(&h,10,Self.checksum(h)); return Data(h+t)
    }
    static func checksum(_ p: [UInt8]) -> UInt16 {
        var sum: UInt32=0
        for i in stride(from:0,to:p.count,by:2) { sum += UInt32(p[i])<<8 | (i+1<p.count ? UInt32(p[i+1]):0) }
        while sum>65535 { sum=(sum&65535)+(sum>>16) }; return ~UInt16(sum)
    }
    static func u16(_ p: [UInt8],_ i: Int) -> UInt16 { UInt16(p[i])<<8|UInt16(p[i+1]) }
    static func u32(_ p: [UInt8],_ i: Int) -> UInt32 { UInt32(u16(p,i))<<16|UInt32(u16(p,i+2)) }
    static func put16(_ p: inout [UInt8],_ i: Int,_ n: UInt16) { p[i]=UInt8(n>>8); p[i+1]=UInt8(n&255) }
    static func put32(_ p: inout [UInt8],_ i: Int,_ n: UInt32) { put16(&p,i,UInt16(n>>16)); put16(&p,i+2,UInt16(n&65535)) }
}
