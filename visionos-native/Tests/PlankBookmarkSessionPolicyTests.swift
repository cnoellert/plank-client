import Foundation

// swiftc -Onone -parse-as-library Sources/Models/HostBookmark.swift
//   Tests/PlankBookmarkSessionPolicyTests.swift -o out && ./out
@main
struct PlankBookmarkSessionPolicyTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }
        let connected = HostBookmark(name: "Workstation", address: "workstation.example",
                                     spatialDisplaySize: .wide3840, streamFrameRate: 60)
        func requires(_ edited: HostBookmark, authenticated: Bool = true) -> Bool {
            PlankBookmarkSessionPolicy.requiresClosure(edited: edited, connected: connected,
                                                       authenticated: authenticated)
        }
        check(!requires(connected), "same mode reconnect retains login")
        var edited = connected
        edited.spatialDisplaySize = .fullHD
        check(requires(edited), "resolution change closes retained login")
        check(!requires(edited, authenticated: false), "logged-out bookmark needs no closure")
        check(!PlankBookmarkSessionPolicy.requiresClosure(edited: edited, connected: nil,
              authenticated: true), "no connected workstation needs no closure")
        edited = connected
        edited.streamFrameRate = 120
        check(requires(edited), "frame-rate change alone closes retained login")
        edited.streamFrameRate = 0
        check(!requires(edited), "invalid frame rate uses the existing normalized default")
        edited = connected
        edited.name = "Renamed workstation"
        check(!requires(edited), "name edit preserves login")
        edited.videoBitrateKbps = 100_000
        check(!requires(edited), "bitrate does not change the display session")
        edited = connected
        edited.address = "other.example"
        check(requires(edited), "address change cannot retain credentials for old endpoint")
        edited = connected
        edited.port += 1
        check(requires(edited), "port change cannot retain old endpoint login")
        edited = connected
        edited.id = UUID()
        edited.spatialDisplaySize = .fullHD
        check(!requires(edited), "editing another bookmark cannot close this workstation")
        // Compare with the actual retained login, even if a saved editor snapshot
        // already carries new settings following an earlier bookmark edit.
        edited = connected
        edited.spatialDisplaySize = .fullHD
        let editorSnapshot = edited
        check(requires(editorSnapshot), "already-saved new mode still differs from retained login")
        print("PlankBookmarkSessionPolicyTests: \(count) checks passed")
    }
}
