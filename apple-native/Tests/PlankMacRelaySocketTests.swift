import Foundation
@preconcurrency import Network

// Real Network sockets and production framing/parser. Only the physical HID
// worker is fake; no network/permission changes or tablet capture in this test.
@MainActor final class MacRelayTestPeers { var peers: [MacRelayPeer] = [] }
@main struct MacRelaySocketTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plank-relay-socket-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        guard let native = MacRelayNative(root: root) else { fatalError("state") }
        let listener = try NWListener(using:.tcp,on:.any)
        let peers = MacRelayTestPeers()
        listener.newConnectionHandler = { connection in Task { @MainActor in
            let peer = MacRelayPeer(connection:connection,native:native,setup:true,routes:["192.0.2.10"],drawingPort:28990,setupPort:28991,event:{_ in})
            peers.peers.append(peer);peer.start()
        } }
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            listener.stateUpdateHandler = { state in switch state {case .ready:c.resume();case .failed(let error):c.resume(throwing:error);default:break} }
            listener.start(queue:.main)
        }
        listener.stateUpdateHandler = nil
        guard let port=listener.port else { fatalError("port") }
        let connection=NWConnection(host:"127.0.0.1",port:port,using:.tcp)
        try await connect(connection)
        let json=Data(#"{"version":1,"id":1,"op":"status","drawingHandoffVersion":2}"#.utf8)
        var record=Data("PLTRTCP1".utf8);record.append(0);record.append(UInt8(json.count));record.append(0);record.append(json)
        // Fragment the preface, length and body. No unauthenticated mutation or
        // drawing metadata may be returned by this discovery channel.
        for byte in record { try await send(connection,Data([byte])) }
        var response=Data()
        while true {
            let bytes=try await receive(connection);precondition(!bytes.isEmpty);response.append(bytes)
            if response.count>=2 {
                let length=Int(response[0])|Int(response[1])<<8
                if response.count==length+2 { break }
            }
        }
        let object=try JSONSerialization.jsonObject(with:Data(response.dropFirst(2))) as! [String:Any]
        precondition(object["headsetAuthorized"] as? Bool == false)
        precondition(object["canManage"] as? Bool == false && object["drawingHandoff"] == nil)
        precondition(object["relayKey"] as? String == native.setupKey.map {String(format:"%02x",$0)}.joined())
        precondition(object["id"] as? Int == 1)
        connection.cancel()
        let duplicate=NWConnection(host:"127.0.0.1",port:port,using:.tcp);try await connect(duplicate)
        let bad=Data(#"{"version":1,"id":1,"op":"status","op":"drawing-enrollment"}"#.utf8)
        var invalid=Data("PLTRTCP1".utf8);invalid.append(0);invalid.append(UInt8(bad.count));invalid.append(0);invalid.append(bad)
        try await send(duplicate,invalid)
        let rejected=try await receive(duplicate);precondition(rejected.isEmpty)
        duplicate.cancel()
        precondition(!peers.peers.isEmpty)
        let authenticatedStatus = peers.peers[0].status(id:2,authorized:true)!
        let approvedObject = try JSONSerialization.jsonObject(with:authenticatedStatus) as! [String:Any]
        let handoff = approvedObject["drawingHandoff"] as! [String:Any]
        precondition(handoff["supported"] as? Bool == true && handoff["state"] as? String == "ready")
        let descriptor = handoff["descriptor"] as! [String:Any]
        precondition(Set(descriptor.keys) == ["version","drawingIdentity","drawingProtocol","routes"])
        let protocolObject = descriptor["drawingProtocol"] as! [String:Any]
        precondition(protocolObject["rawHID"] as? Int == 1 && protocolObject["linkType"] as? Int == 2)
        let endpoints = descriptor["routes"] as! [[String:Any]]
        precondition(endpoints.count == 1 && endpoints[0]["port"] as? Int == 28990)
        precondition(approvedObject["headsetAuthorized"] as? Bool == true)
        for peer in peers.peers {peer.close("Test finished")};listener.cancel()
        try await Task.sleep(for:.milliseconds(100))
        print("Mac Relay real socket: fragmented discovery, bounded public metadata and duplicate-field refusal passed")
    }
    static func connect(_ connection:NWConnection) async throws {
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            connection.stateUpdateHandler={state in switch state {case .ready:c.resume();case .failed(let error):c.resume(throwing:error);default:break}}
            connection.start(queue:.main)
        };connection.stateUpdateHandler=nil
    }
    static func send(_ connection:NWConnection,_ data:Data) async throws {
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in connection.send(content:data,completion:.contentProcessed {error in if let error {c.resume(throwing:error)}else{c.resume()}}) }
    }
    static func receive(_ connection:NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { c in connection.receive(minimumIncompleteLength:1,maximumLength:8192){data,_,_,error in if let error {c.resume(throwing:error)}else{c.resume(returning:data ?? Data())}} }
    }
}
