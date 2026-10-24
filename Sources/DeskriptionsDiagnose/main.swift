import Foundation
import CoreGraphics
import DeskriptionsCore

let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("deskriptions-lab", isDirectory: true)
let overrideURL = root.appendingPathComponent("associations.json")

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--associate" {
    let pieces = CommandLine.arguments[2].split(separator: ":")
    guard pieces.count == 2, let extensionID = Int(pieces[0]), let nativeID = UInt32(pieces[1]) else {
        fatalError("Expected --associate EXTENSION_WINDOW_ID:NATIVE_WINDOW_ID")
    }
    var overrides = (try? JSONDecoder().decode([String: UInt32].self, from: Data(contentsOf: overrideURL))) ?? [:]
    overrides[String(extensionID)] = nativeID
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(overrides).write(to: overrideURL, options: .atomic)
    print("Recorded explicit user association \(extensionID) → \(nativeID)")
    exit(0)
}

let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let native = rows.compactMap { row -> NativeWindow? in
    guard let id = row[kCGWindowNumber as String] as? UInt32,
          let pid = row[kCGWindowOwnerPID as String] as? Int32,
          let owner = row[kCGWindowOwnerName as String] as? String,
          owner.localizedCaseInsensitiveContains("Chrome"),
          let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
          let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
    return .init(windowID: id, ownerPID: pid, ownerName: owner, title: row[kCGWindowName as String] as? String ?? "", bounds: .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), onScreen: row[kCGWindowIsOnscreen as String] as? Bool ?? false)
}

let files = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("profile-") }
let overrides = (try? JSONDecoder().decode([String: UInt32].self, from: Data(contentsOf: overrideURL))) ?? [:]
var report: [[String: Any]] = []
for file in files {
    guard let data = try? Data(contentsOf: file), let hello = try? JSONDecoder().decode(ExtensionHello.self, from: data) else { continue }
    for association in WindowMatcher.associate(browser: hello.windows, native: native) {
        let explicit = overrides[String(association.browserWindowID)]
        report.append([
            "installationID": hello.installationID,
            "connectionSessionID": hello.sessionID,
            "extensionWindowID": association.browserWindowID,
            "nativeWindowID": explicit ?? association.nativeWindowID as Any,
            "status": explicit == nil ? association.status.rawValue : "matched",
            "reason": explicit == nil ? association.reason : "explicit user association"
        ])
    }
}
let output: [String: Any] = [
    "nativeChromeWindows": native.map { ["windowID": $0.windowID, "title": $0.title, "onScreenCurrentSpace": $0.onScreen, "bounds": ["x": $0.bounds.x, "y": $0.bounds.y, "width": $0.bounds.width, "height": $0.bounds.height]] },
    "associations": report,
    "desktopMembershipCaveat": "Public CGWindowList exposes current onscreen visibility, not a stable macOS Space identifier."
]
let encoded = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: encoded, as: UTF8.self))
