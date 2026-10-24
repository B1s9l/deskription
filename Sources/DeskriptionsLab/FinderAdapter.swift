import AppKit
import DeskriptionsCore

struct FinderFolderObservation: Equatable {
    let windowID: Int
    let path: String
    let frame: Rect
    let onScreen: Bool
}

@MainActor
final class FinderAdapter {
    enum AdapterError: LocalizedError {
        case automationDenied(String)
        case malformedReply
        case folderUnavailable(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .automationDenied(let message): return "Finder access failed: \(message). Allow Deskriptions to control Finder in Privacy & Security → Automation."
            case .malformedReply: return "Finder returned an unreadable window inventory."
            case .folderUnavailable(let path): return "The saved Finder folder is unavailable: \(path)"
            case .verificationFailed(let path): return "Finder did not confirm that it opened: \(path)"
            }
        }
    }

    func inventory() throws -> [FinderFolderObservation] {
        let source = """
        tell application "Finder"
            set resultRows to {}
            repeat with finderWindow in (get Finder windows)
                try
                    set folderPath to POSIX path of (target of finderWindow as alias)
                    set {leftEdge, topEdge, rightEdge, bottomEdge} to bounds of finderWindow
                    set end of resultRows to {(id of finderWindow), folderPath, leftEdge, topEdge, rightEdge, bottomEdge}
                end try
            end repeat
            return resultRows
        end tell
        """
        let descriptor = try run(source)
        let native = nativeFinderWindows()
        var result: [FinderFolderObservation] = []
        guard descriptor.numberOfItems > 0 else { return result }
        for index in 1...descriptor.numberOfItems {
            guard let row = descriptor.atIndex(index), row.numberOfItems >= 6,
                  let path = row.atIndex(2)?.stringValue else { throw AdapterError.malformedReply }
            let left = Double(row.atIndex(3)?.int32Value ?? 0), top = Double(row.atIndex(4)?.int32Value ?? 0)
            let right = Double(row.atIndex(5)?.int32Value ?? 0), bottom = Double(row.atIndex(6)?.int32Value ?? 0)
            let frame = Rect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
            let matches = native.filter { abs($0.bounds.x-frame.x) <= 4 && abs($0.bounds.y-frame.y) <= 4 && abs($0.bounds.width-frame.width) <= 4 && abs($0.bounds.height-frame.height) <= 4 }
            result.append(.init(windowID: Int(row.atIndex(1)?.int32Value ?? 0), path: path, frame: frame, onScreen: matches.count == 1 && matches[0].onScreen))
        }
        return result
    }

    func restore(_ saved: SavedFinderFolder) throws -> FinderFolderObservation {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: saved.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AdapterError.folderUnavailable(saved.path) }
        let escaped = saved.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let left=Int(saved.frame.x), top=Int(saved.frame.y), right=Int(saved.frame.x+saved.frame.width), bottom=Int(saved.frame.y+saved.frame.height)
        let descriptor = try run("""
        tell application "Finder"
            activate
            set targetFolder to (POSIX file "\(escaped)") as alias
            set restoredWindow to make new Finder window to targetFolder
            set bounds of restoredWindow to {\(left), \(top), \(right), \(bottom)}
            set index of restoredWindow to 1
            return id of restoredWindow
        end tell
        """)
        let restoredID = Int(descriptor.int32Value)
        guard let verified = try inventory().first(where: { $0.windowID == restoredID && URL(fileURLWithPath: $0.path).standardizedFileURL.path == URL(fileURLWithPath: saved.path).standardizedFileURL.path }) else { throw AdapterError.verificationFailed(saved.path) }
        return verified
    }

    func bringToFront(_ observation: FinderFolderObservation) throws {
        let descriptor = try run("""
        tell application "Finder"
            activate
            set matchingWindows to every Finder window whose id is \(observation.windowID)
            if (count of matchingWindows) is not 1 then error "The saved Finder window is no longer uniquely identifiable."
            set index of item 1 of matchingWindows to 1
            return id of item 1 of matchingWindows
        end tell
        """)
        guard Int(descriptor.int32Value) == observation.windowID else { throw AdapterError.verificationFailed(observation.path) }
    }

    private func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw AdapterError.malformedReply }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { throw AdapterError.automationDenied(error[NSAppleScript.errorMessage] as? String ?? "Apple Events error \(error[NSAppleScript.errorNumber] ?? "unknown")") }
        return result
    }

    private func nativeFinderWindows() -> [NativeWindow] {
        (CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []).compactMap { row in
            guard (row[kCGWindowOwnerName as String] as? String) == "Finder",
                  let id=row[kCGWindowNumber as String] as? UInt32,
                  let pid=row[kCGWindowOwnerPID as String] as? Int32,
                  let dictionary=row[kCGWindowBounds as String] as? NSDictionary,
                  let frame=CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  (row[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return NativeWindow(windowID:id, ownerPID:pid, ownerName:"Finder", title:"", bounds:.init(x:frame.minX,y:frame.minY,width:frame.width,height:frame.height), onScreen:row[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }
}
