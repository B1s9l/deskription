import Foundation
import Darwin
import AppKit

// Chromium native messaging transport. Each profile starts one process. The host
// executable name is browser-specific and is installed by Deskriptions into that
// browser's own NativeMessagingHosts directory. This native fact, not extension
// JavaScript or a user-agent string, establishes the browser bundle identity.
// journals the latest validated message per installation so the diagnostic CLI/app can
// inspect it without conflating Chrome's session-scoped window IDs with native IDs.
let stateRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("deskriptions-lab", isDirectory: true)
try? FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

let supportedBrowserIDs = Set(["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"])
let parentBrowser = NSRunningApplication(processIdentifier: getppid()).flatMap(\.bundleIdentifier).flatMap { supportedBrowserIDs.contains($0) ? $0 : nil }
let verifiedBrowser = parentBrowser
let browserIdentitySource = "native-parent-process-v1"

func readExact(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let chunk = FileHandle.standardInput.readData(ofLength: count - data.count)
        if chunk.isEmpty { return nil }; data.append(chunk)
    }
    return data
}

func send(_ object: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: object), body.count <= 1_048_576 else { return }
    var length = UInt32(body.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: 4)); FileHandle.standardOutput.write(body)
}

while let header = readExact(4) {
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    guard length > 0, length <= 1_048_576, let body = readExact(Int(length)),
          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        send(["type": "error", "code": "invalid_message", "message": "Malformed or oversized native message"]); continue
    }
    guard (json["protocolVersion"] as? Int) == 1 else {
        send(["type": "error", "code": "incompatible_protocol", "supported": [1]]); continue
    }
    guard let verifiedBrowser else {
        send(["type": "error", "code": "unverified_browser_host", "message": "Repair the Chromium bridge registration in Deskriptions Setup."]); continue
    }
    var verifiedJSON = json
    verifiedJSON["browser"] = verifiedBrowser
    verifiedJSON["browserIdentitySource"] = browserIdentitySource
    guard let verifiedBody = try? JSONSerialization.data(withJSONObject: verifiedJSON) else {
        send(["type": "error", "code": "invalid_message"]); continue
    }
    let identity = (json["installationID"] as? String)?.filter { $0.isLetter || $0.isNumber || $0 == "-" } ?? "unknown"
    let scopedIdentity = "\(verifiedBrowser)-\(identity)".map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
    let file = stateRoot.appendingPathComponent("profile-\(String(scopedIdentity)).json")
    do {
        try verifiedBody.write(to: file, options: .atomic)
        if let requestID = json["requestID"] as? String {
            try verifiedBody.write(to: stateRoot.appendingPathComponent("result-\(requestID).json"), options: .atomic)
        }
        let command = stateRoot.appendingPathComponent("command-\(String(scopedIdentity)).json")
        if let commandBody = try? Data(contentsOf: command),
           let commandJSON = try? JSONSerialization.jsonObject(with: commandBody) as? [String: Any] {
            send(commandJSON)
            try? FileManager.default.removeItem(at: command)
        } else {
            send(["type": "ack", "protocolVersion": 1, "requestID": json["requestID"] ?? NSNull(), "receivedAt": ISO8601DateFormatter().string(from: Date())])
        }
    } catch {
        send(["type": "error", "code": "state_write_failed", "message": error.localizedDescription])
    }
}

