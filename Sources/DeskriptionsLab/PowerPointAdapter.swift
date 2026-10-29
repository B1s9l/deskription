import AppKit
import ApplicationServices

@MainActor
final class PowerPointAdapter: DocumentDiscoveryAdapter {
    static let bundleIdentifier = "com.microsoft.Powerpoint"
    let applicationBundleID = PowerPointAdapter.bundleIdentifier
    let applicationDisplayName = "Microsoft PowerPoint"
    private(set) var hasUnidentifiedPresentations = false

    enum AdapterError: LocalizedError {
        case automationDenied
        case automation(String)
        case identityUnavailable

        var errorDescription: String? {
            switch self {
            case .automationDenied:
                return "PowerPoint document discovery requires Automation access. Allow Deskriptions to control Microsoft PowerPoint in System Settings → Privacy & Security → Automation, then reopen Save Desktop."
            case .automation(let detail):
                return "PowerPoint document discovery failed: \(detail)"
            case .identityUnavailable:
                return "PowerPoint has an open presentation whose exact saved file path is unavailable. It remains available through application-only restoration."
            }
        }
    }

    func inventoryWithRetry() async throws -> [DocumentObservation] {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first(where: { !$0.isTerminated }) else {
            hasUnidentifiedPresentations = false
            return []
        }
        let recordSeparator = "\u{001e}"
        let fieldSeparator = "\u{001f}"
        let source = """
        tell application id "\(Self.bundleIdentifier)"
            set output to ""
            repeat with itemPresentation in presentations
                set presentationName to ""
                set presentationFullName to ""
                set presentationPath to ""
                try
                    set presentationName to name of itemPresentation as text
                end try
                try
                    set presentationFullName to full name of itemPresentation as text
                end try
                try
                    set presentationPath to path of itemPresentation as text
                end try
                set output to output & presentationName & "\(fieldSeparator)" & presentationFullName & "\(fieldSeparator)" & presentationPath & "\(recordSeparator)"
            end repeat
            return output
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source), let output = script.executeAndReturnError(&error).stringValue else {
            let number = error?[NSAppleScript.errorNumber] as? Int
            if number == -1743 { throw AdapterError.automationDenied }
            let message = (error?[NSAppleScript.errorMessage] as? String) ?? "unknown Apple Event error"
            throw AdapterError.automation(message)
        }

        var unidentified = false
        var observations: [DocumentObservation] = []
        for record in output.split(separator: Character(recordSeparator), omittingEmptySubsequences: true) {
            let fields = record.split(separator: Character(fieldSeparator), omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { unidentified = true; continue }
            let declaredName = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = exactFileURL(fullName: fields[1], directory: fields[2], name: declaredName) else {
                unidentified = true
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                unidentified = true
                continue
            }
            let normalized = url.standardizedFileURL
            let name = declaredName.isEmpty ? normalized.lastPathComponent : declaredName
            observations.append(DocumentObservation(applicationBundleID: Self.bundleIdentifier,
                                                    applicationBundlePath: running.bundleURL?.path,
                                                    path: normalized.path,
                                                    displayName: name,
                                                    onScreen: isOnScreen(path: normalized.path, displayName: name, pid: running.processIdentifier),
                                                    identityMetadata: ["discovery": "PowerPointAutomationFullName"]))
        }
        hasUnidentifiedPresentations = unidentified
        return observations.reduce(into: []) { result, item in
            if !result.contains(where: { $0.path == item.path }) { result.append(item) }
        }
    }

    func bringToFront(path: String) throws {
        if AXIsProcessTrusted(), let window = accessibilityWindow(path: path),
           AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
            _ = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first?.activate(options: [.activateAllWindows])
            return
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first(where: { !$0.isTerminated }),
              running.activate(options: [.activateAllWindows]) else {
            throw AdapterError.automation("PowerPoint is running, but its presentation could not be brought to the front.")
        }
    }

    private func exactFileURL(fullName: String, directory: String, name: String) -> URL? {
        let full = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.hasPrefix("file:"), let url = URL(string: full), url.isFileURL { return url }
        if full.hasPrefix("/") { return URL(fileURLWithPath: full) }
        let folder = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard folder.hasPrefix("/"), !name.isEmpty else { return nil }
        return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name)
    }

    private func isOnScreen(path: String, displayName: String, pid: pid_t) -> Bool {
        if AXIsProcessTrusted(), accessibilityWindow(path: path) != nil { return true }
        let baseName = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        return nativeWindows(pid: pid).contains { window in
            window.onScreen && (!baseName.isEmpty && window.title.localizedCaseInsensitiveContains(baseName))
        }
    }

    private func accessibilityWindow(path: String) -> AXUIElement? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier) where !app.isTerminated {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            if let match = windows.first(where: { window in
                var document: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &document) == .success else { return false }
                if let url = document as? URL { return url.standardizedFileURL.path == wanted }
                if let string = document as? String {
                    let url = string.hasPrefix("file:") ? URL(string: string) : URL(fileURLWithPath: string)
                    return url?.standardizedFileURL.path == wanted
                }
                return false
            }) { return match }
        }
        return nil
    }

    private func nativeWindows(pid: pid_t) -> [(title: String, onScreen: Bool)] {
        (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (row[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (row[kCGWindowName as String] as? String ?? "", row[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }
}
