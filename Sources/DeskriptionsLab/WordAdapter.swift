import AppKit
import ApplicationServices

final class WordAdapter: DocumentDiscoveryAdapter {
    static let bundleIdentifier = "com.microsoft.Word"
    let applicationBundleID = WordAdapter.bundleIdentifier
    let applicationDisplayName = "Microsoft Word"
    private var cachedInventory: (Date, [DocumentObservation])?

    enum AdapterError: LocalizedError {
        case automationDenied, automationTimedOut
        case automation(String)
        var errorDescription: String? { switch self {
        case .automationDenied: return "Word document discovery requires Automation access. Allow Deskriptions to control Microsoft Word in System Settings → Privacy & Security → Automation."
        case .automationTimedOut: return "Word did not answer the Automation request within 4 seconds. Check Deskriptions → Microsoft Word in Privacy & Security → Automation."
        case .automation(let detail): return "Word document discovery failed: \(detail)"
        } }
    }

    func inventoryWithRetry() async throws -> [DocumentObservation] {
        if let cachedInventory, Date().timeIntervalSince(cachedInventory.0) < 1.5 { return cachedInventory.1 }
        guard let running = runningApplication() else { cachedInventory = (Date(), []); return [] }
        let ax = AXIsProcessTrusted() ? accessibilityInventory(running) : []
        let paths: [String]
        do { paths = try await automationPaths() }
        catch { if !ax.isEmpty { cachedInventory = (Date(), ax); return ax }; throw error }
        let observations = observations(paths: paths, running: running)
        let result = observations.isEmpty ? ax : observations
        cachedInventory = (Date(), result)
        return result
    }

    func observation(forPath path: String) async throws -> DocumentObservation? {
        guard AXIsProcessTrusted(), let running = runningApplication(), accessibilityWindow(path: path) != nil else { return nil }
        return observation(path: path, running: running, discovery: "AXDocument-targeted")
    }

    func finalVerification(forPath path: String) async throws -> DocumentObservation? {
        if let ax = try await observation(forPath: path) { return ax }
        let wanted = standardized(path)
        guard try await automationPaths().contains(where: { standardized($0) == wanted }), let running = runningApplication() else { return nil }
        return observation(path: wanted, running: running, discovery: "WordAutomationVerification")
    }

    func bringToFront(path: String) throws {
        if AXIsProcessTrusted(), let window = accessibilityWindow(path: path), AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success { _ = runningApplication()?.activate(options: [.activateAllWindows]); return }
        guard runningApplication()?.activate(options: [.activateAllWindows]) == true else { throw AdapterError.automation("Word is running, but its document could not be brought to the front.") }
    }

    private func automationPaths() async throws -> [String] {
        let separator = "\u{001e}"
        let source = """
        with timeout of 3 seconds
        tell application id "\(Self.bundleIdentifier)"
            set rawPaths to full name of every document
            set documentPaths to {}
            repeat with rawPath in rawPaths
                try
                    set pathText to rawPath as text
                    if pathText starts with "/" then
                        set end of documentPaths to pathText
                    else
                        set end of documentPaths to POSIX path of (pathText as alias)
                    end if
                end try
            end repeat
            set oldDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to "\(separator)"
            set output to documentPaths as text
            set AppleScript's text item delimiters to oldDelimiters
            return output
        end tell
        end timeout
        """
        return try await executeAppleScript(source).split(separator: Character(separator), omittingEmptySubsequences: true).map(String.init)
    }

    private func observations(paths: [String], running: NSRunningApplication) -> [DocumentObservation] { paths.compactMap { raw -> DocumentObservation? in
        guard let path = filePath(raw) else { return nil }
        return observation(path: path, running: running, discovery: "WordAutomationFullName")
    }.reduce(into: [DocumentObservation]()) { result, item in if !result.contains(where: { $0.path == item.path }) { result.append(item) } } }

    private func observation(path: String, running: NSRunningApplication, discovery: String) -> DocumentObservation? {
        let path = standardized(path); var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue, FileManager.default.isReadableFile(atPath: path) else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return .init(applicationBundleID: Self.bundleIdentifier, applicationBundlePath: running.bundleURL?.path, path: path, displayName: name, onScreen: isOnScreen(path: path, displayName: name, pid: running.processIdentifier), identityMetadata: ["discovery": discovery])
    }

    private func accessibilityInventory(_ app: NSRunningApplication) -> [DocumentObservation] { accessibilityWindows(app).compactMap { window -> DocumentObservation? in
        var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value) == .success, let value, let path = documentPath(value) else { return nil }
        return observation(path: path, running: app, discovery: "AXDocument")
    }.reduce(into: [DocumentObservation]()) { result, item in if !result.contains(where: { $0.path == item.path }) { result.append(item) } } }

    private func accessibilityWindow(path: String) -> AXUIElement? { let wanted = standardized(path); return runningApplication().flatMap { app in accessibilityWindows(app).first { window in
        var value: CFTypeRef?; return AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value) == .success && value.flatMap(documentPath).map(standardized) == wanted
    } } }
    private func accessibilityWindows(_ app: NSRunningApplication) -> [AXUIElement] { let element = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(element, 2); var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success ? value as? [AXUIElement] ?? [] : [] }
    private func documentPath(_ value: CFTypeRef) -> String? { if CFGetTypeID(value) == CFURLGetTypeID() { return (value as? URL)?.path }; guard let string = value as? String else { return nil }; return filePath(string) }
    private func filePath(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("file:"), let url = URL(string: value), url.isFileURL { return url.path }
        if value.hasPrefix("/") { return value }
        return nil
    }
    private func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    private func runningApplication() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first { !$0.isTerminated } }
    private func isOnScreen(path: String, displayName: String, pid: pid_t) -> Bool { if AXIsProcessTrusted(), accessibilityWindow(path: path) != nil { return true }; let base = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent; return nativeWindows(pid: pid).contains { $0.1 && $0.0.localizedCaseInsensitiveContains(base) } }
    private func nativeWindows(pid: pid_t) -> [(String, Bool)] { (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { row in guard (row[kCGWindowOwnerPID as String] as? Int32) == pid, (row[kCGWindowLayer as String] as? Int) == 0 else { return nil }; return (row[kCGWindowName as String] as? String ?? "", row[kCGWindowIsOnscreen as String] as? Bool ?? false) } }

    private final class Completion: @unchecked Sendable { let lock = NSLock(); var finished = false }
    private func executeAppleScript(_ source: String) async throws -> String { try await withCheckedThrowingContinuation { continuation in
        let completion = Completion(); let finish: @Sendable (Result<String, Error>) -> Void = { result in completion.lock.lock(); guard !completion.finished else { completion.lock.unlock(); return }; completion.finished = true; completion.lock.unlock(); continuation.resume(with: result) }
        DispatchQueue.global(qos: .userInitiated).async { guard let script = NSAppleScript(source: source) else { finish(.failure(AdapterError.automation("The Automation request could not be prepared."))); return }; var info: NSDictionary?; let reply = script.executeAndReturnError(&info); if let info { let code = info[NSAppleScript.errorNumber] as? Int, message = info[NSAppleScript.errorMessage] as? String ?? info.description; finish(.failure(code == -1743 ? AdapterError.automationDenied : code == -1712 ? AdapterError.automationTimedOut : AdapterError.automation(message))) } else { finish(.success(reply.stringValue ?? "")) } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) { completion.lock.lock(); let pending = !completion.finished; completion.lock.unlock(); if pending { finish(.failure(AdapterError.automationTimedOut)) } }
    } }
}
