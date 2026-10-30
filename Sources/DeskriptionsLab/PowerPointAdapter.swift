import AppKit
import ApplicationServices

final class PowerPointAdapter: DocumentDiscoveryAdapter {
    static let bundleIdentifier = "com.microsoft.Powerpoint"
    let applicationBundleID = PowerPointAdapter.bundleIdentifier
    let applicationDisplayName = "Microsoft PowerPoint"
    private(set) var hasUnidentifiedPresentations = false
    private var cachedInventory: (date: Date, observations: [DocumentObservation], unidentified: Bool)?

    enum AdapterError: LocalizedError {
        case automationDenied
        case automationTimedOut
        case automation(String)
        case identityUnavailable

        var errorDescription: String? {
            switch self {
            case .automationDenied:
                return "PowerPoint document discovery requires Automation access. Allow Deskriptions to control Microsoft PowerPoint in System Settings → Privacy & Security → Automation, then reopen Save Desktop."
            case .automationTimedOut:
                return "PowerPoint did not answer the Automation request within 4 seconds. Check for a permission prompt, then verify Deskriptions → Microsoft PowerPoint in Privacy & Security → Automation."
            case .automation(let detail):
                return "PowerPoint document discovery failed: \(detail)"
            case .identityUnavailable:
                return "PowerPoint has an open presentation whose exact saved file path is unavailable. It remains available through application-only restoration."
            }
        }
    }

    func inventoryWithRetry() async throws -> [DocumentObservation] {
        if let cachedInventory, Date().timeIntervalSince(cachedInventory.date) < 1.5 {
            hasUnidentifiedPresentations = cachedInventory.unidentified
            return cachedInventory.observations
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first(where: { !$0.isTerminated }) else {
            hasUnidentifiedPresentations = false
            cachedInventory = (Date(), [], false)
            return []
        }
        var accessibilityFallback: [DocumentObservation] = []
        if AXIsProcessTrusted() {
            let accessibility = accessibilityInventory(running)
            let plausibleDocumentWindowCount = nativeWindows(pid: running.processIdentifier).filter { window in
                let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return !title.isEmpty && title.localizedCaseInsensitiveCompare(applicationDisplayName) != .orderedSame
            }.count
            if !accessibility.documents.isEmpty && plausibleDocumentWindowCount <= accessibility.documents.count {
                hasUnidentifiedPresentations = false
                cachedInventory = (Date(), accessibility.documents, false)
                return accessibility.documents
            }
            accessibilityFallback = accessibility.documents
        }
        let recordSeparator = "\u{001e}"
        let source = """
        with timeout of 3 seconds
        tell application id "\(Self.bundleIdentifier)"
            set presentationPaths to full name of every presentation
            set previousDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to "\(recordSeparator)"
            set output to presentationPaths as text
            set AppleScript's text item delimiters to previousDelimiters
            return output
        end tell
        end timeout
        """
        let output: String
        do { output = try await executeAppleScript(source) }
        catch {
            if !accessibilityFallback.isEmpty {
                hasUnidentifiedPresentations = true
                cachedInventory = (Date(), accessibilityFallback, true)
                return accessibilityFallback
            }
            throw error
        }

        var unidentified = false
        var observations: [DocumentObservation] = []
        for record in output.split(separator: Character(recordSeparator), omittingEmptySubsequences: true) {
            let fullName = String(record).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = exactFileURL(fullName: fullName, directory: "", name: "") else {
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
            let name = normalized.lastPathComponent
            observations.append(DocumentObservation(applicationBundleID: Self.bundleIdentifier,
                                                    applicationBundlePath: running.bundleURL?.path,
                                                    path: normalized.path,
                                                    displayName: name,
                                                    onScreen: isOnScreen(path: normalized.path, displayName: name, pid: running.processIdentifier),
                                                    identityMetadata: ["discovery": "PowerPointAutomationFullName"]))
        }
        hasUnidentifiedPresentations = unidentified
        let unique = observations.reduce(into: [DocumentObservation]()) { result, item in
            if !result.contains(where: { $0.path == item.path }) { result.append(item) }
        }
        cachedInventory = (Date(), unique, unidentified)
        return unique
    }

    func accessibilityInventoryForDiagnostics() -> (documents: [DocumentObservation], windowCount: Int) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first(where: { !$0.isTerminated }) else { return ([], 0) }
        return accessibilityInventory(running)
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

    func observation(forPath path: String) async throws -> DocumentObservation? {
        guard AXIsProcessTrusted(), let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first(where: { !$0.isTerminated }),
              accessibilityWindow(path: path) != nil else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL
        return DocumentObservation(applicationBundleID: Self.bundleIdentifier,
                                   applicationBundlePath: running.bundleURL?.path,
                                   path: normalized.path,
                                   displayName: normalized.lastPathComponent,
                                   onScreen: !running.isHidden,
                                   identityMetadata: ["discovery": "AXDocument-targeted"])
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
            AXUIElementSetMessagingTimeout(application, 2)
            let windows = accessibilityWindows(application)
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

    private func accessibilityInventory(_ app: NSRunningApplication) -> (documents: [DocumentObservation], windowCount: Int) {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 2)
        let windows = accessibilityWindows(application)
        let documents = windows.compactMap { window -> DocumentObservation? in
            var documentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentValue) == .success,
                  let documentValue, let url = documentURL(documentValue), url.isFileURL else { return nil }
            let normalized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: normalized.path) else { return nil }
            var minimizedValue: CFTypeRef?
            let minimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success ? (minimizedValue as? Bool ?? false) : false
            return DocumentObservation(applicationBundleID: Self.bundleIdentifier,
                                       applicationBundlePath: app.bundleURL?.path,
                                       path: normalized.path,
                                       displayName: normalized.lastPathComponent,
                                       onScreen: !app.isHidden && !minimized,
                                       identityMetadata: ["discovery": "AXDocument"])
        }.reduce(into: [DocumentObservation]()) { result, item in
            if !result.contains(where: { $0.path == item.path }) { result.append(item) }
        }
        return (documents, windows.count)
    }

    private func accessibilityWindows(_ application: AXUIElement) -> [AXUIElement] {
        var directValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &directValue) == .success,
           let direct = directValue as? [AXUIElement], !direct.isEmpty { return direct }

        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focused = focusedValue as! AXUIElement? { return [focused] }
        return []
    }

    private func documentURL(_ value: CFTypeRef) -> URL? {
        if CFGetTypeID(value) == CFURLGetTypeID() { return value as? URL }
        guard let string = value as? String else { return nil }
        if string.hasPrefix("file:") { return URL(string: string) }
        return string.hasPrefix("/") ? URL(fileURLWithPath: string) : nil
    }

    private func nativeWindows(pid: pid_t) -> [(title: String, onScreen: Bool)] {
        (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (row[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (row[kCGWindowName as String] as? String ?? "", row[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    private final class ScriptCompletion: @unchecked Sendable {
        let lock = NSLock()
        var finished = false
    }

    /// Run the Apple Event away from the UI actor, but in this process so macOS
    /// applies Deskriptions' Automation authorization rather than osascript's.
    /// The continuation is bounded even if Office stops answering; the worker
    /// may finish later, but cannot wedge Save Desktop.
    private func executeAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let completion = ScriptCompletion()
            let finish: @Sendable (Result<String, Error>) -> Void = { result in
                completion.lock.lock()
                guard !completion.finished else { completion.lock.unlock(); return }
                completion.finished = true
                completion.lock.unlock()
                continuation.resume(with: result)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                guard let script = NSAppleScript(source: source) else {
                    finish(.failure(AdapterError.automation("The PowerPoint Automation request could not be prepared.")))
                    return
                }
                var errorInfo: NSDictionary?
                let reply = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let code = errorInfo[NSAppleScript.errorNumber] as? Int
                    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? errorInfo.description
                    if code == -1743 { finish(.failure(AdapterError.automationDenied)) }
                    else if code == -1712 { finish(.failure(AdapterError.automationTimedOut)) }
                    else { finish(.failure(AdapterError.automation(message))) }
                } else {
                    finish(.success(reply.stringValue ?? ""))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                completion.lock.lock()
                let shouldStop = !completion.finished
                completion.lock.unlock()
                if shouldStop {
                    finish(.failure(AdapterError.automationTimedOut))
                }
            }
        }
    }
}
