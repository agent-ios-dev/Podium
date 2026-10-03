import XCTest
import Network
@testable import Podium

final class PacketNetworkTests: XCTestCase {
    func testGuestTCPConversationReachesHostSocketAndReturnsValidPackets() throws {
        let queue=DispatchQueue(label:"NAT-test-server"), ready=expectation(description:"server ready")
        let listener=try NWListener(using:.tcp,on:.any)
        listener.stateUpdateHandler = { if case .ready=$0 { ready.fulfill() } }
        listener.newConnectionHandler = { c in
            c.start(queue:queue)
            c.receive(minimumIncompleteLength:1,maximumLength:4096) { data,_,_,_ in
                XCTAssertEqual(String(data:data ?? Data(),encoding:.utf8),"GET / HTTP/1.0\r\n\r\n")
                c.send(content:Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK".utf8),completion:.contentProcessed { _ in })
            }
        }
        listener.start(queue:queue); wait(for:[ready],timeout:5); defer { listener.cancel() }
        let port=try XCTUnwrap(listener.port).rawValue, net=PacketNetwork()
        defer { net.stop() }
        let response=expectation(description:"guest got real HTTP response")
        var sequence: UInt32=101, acknowledged: UInt32=0, established=false
        net.onReceive = { data in
            let p=[UInt8](data)
            XCTAssertEqual(PacketNetwork.checksum(Array(p.prefix(20))),0)
            let pseudo=Array(p[12..<20])+[0,6,UInt8((p.count-20)>>8),UInt8((p.count-20)&255)]
            XCTAssertEqual(PacketNetwork.checksum(pseudo+Array(p.dropFirst(20))),0)
            acknowledged=PacketNetwork.u32(p,24)
            if p[33]&2 != 0 && !established {
                established=true; acknowledged &+= 1
                net.send(self.packet(port:port,seq:sequence,ack:acknowledged,flags:0x10))
                let body=Data("GET / HTTP/1.0\r\n\r\n".utf8)
                net.send(self.packet(port:port,seq:sequence,ack:acknowledged,flags:0x18,body:body)); sequence &+= UInt32(body.count)
            } else if p.count>40 {
                XCTAssertTrue(String(decoding:p.dropFirst(40),as:UTF8.self).contains("200 OK"))
                acknowledged &+= UInt32(p.count-40)
                net.send(self.packet(port:port,seq:sequence,ack:acknowledged,flags:0x10)); response.fulfill()
            }
        }
        net.send(packet(port:port,seq:100,ack:0,flags:2)); wait(for:[response],timeout:10)
    }
    private func packet(port: UInt16,seq: UInt32,ack: UInt32,flags: UInt8,body: Data=Data()) -> Data {
        var p=[UInt8](repeating:0,count:40); p[0]=0x45; p[9]=6
        p.replaceSubrange(12..<16,with:[10,0,2,15]); p.replaceSubrange(16..<20,with:[127,0,0,1])
        PacketNetwork.put16(&p,2,UInt16(p.count+body.count)); PacketNetwork.put16(&p,20,49152); PacketNetwork.put16(&p,22,port)
        PacketNetwork.put32(&p,24,seq); PacketNetwork.put32(&p,28,ack); p[32]=0x50; p[33]=flags
        p += body; return Data(p)
    }
}
