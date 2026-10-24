import AppKit
import DeskriptionsCore

struct NoteObservation: Equatable { let identifier: String; let displayName: String; let onScreen: Bool }

@MainActor
final class NotesAdapter {
    static let bundleIdentifier = "com.apple.Notes"
    enum AdapterError: LocalizedError {
        case automation(String), malformedReply, unavailable(String), verificationFailed(String)
        var errorDescription: String? { switch self {
        case .automation(let message): return "Notes access failed: \(message). Allow Deskriptions to control Notes in Privacy & Security → Automation."
        case .malformedReply: return "Notes returned an unreadable selected-note identity."
        case .unavailable(let name): return "The saved note is deleted, inaccessible, or unavailable: \(name)"
        case .verificationFailed(let name): return "Notes could not verify that it showed: \(name)"
        } }
    }

    func inventory() throws -> [NoteObservation] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty else { return [] }
        let descriptor = try run("""
        tell application "Notes"
            set rows to {}
            set selectedNotes to selection
            if selectedNotes is missing value then return rows
            repeat with selectedNote in selectedNotes
                try
                    set noteIdentifier to id of selectedNote
                    set noteName to name of selectedNote
                    set end of rows to {noteIdentifier, noteName}
                end try
            end repeat
            return rows
        end tell
        """)
        let visible = notesOnScreen()
        guard descriptor.numberOfItems > 0 else { return [] }
        return try (1...descriptor.numberOfItems).map { index in
            guard let row = descriptor.atIndex(index), let identifier = row.atIndex(1)?.stringValue, let name = row.atIndex(2)?.stringValue else { throw AdapterError.malformedReply }
            return NoteObservation(identifier: identifier, displayName: name, onScreen: visible)
        }
    }

    func restore(_ saved: SavedNote) async throws {
        try await launchIfNeeded()
        let identifier = escaped(saved.noteIdentifier), name = escaped(saved.displayName)
        let result = try run("""
        tell application "Notes"
            set matches to every note whose id is "\(identifier)"
            if (count of matches) is not 1 then error "Saved note is unavailable"
            set targetNote to item 1 of matches
            show targetNote separately true
            activate
            return id of targetNote
        end tell
        """)
        guard result.stringValue == saved.noteIdentifier else { throw AdapterError.verificationFailed(name) }
    }

    func requestAutomationPermission() async throws {
        try await launchIfNeeded()
        _ = try run("""
        tell application "Notes"
            return count of selection
        end tell
        """)
    }

    private func launchIfNeeded() async throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty else { return }
        guard let notesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else { throw AdapterError.unavailable("Apple Notes") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: notesURL, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func run(_ source: String) throws -> NSAppleEventDescriptor { guard let script = NSAppleScript(source: source) else { throw AdapterError.malformedReply }; var error: NSDictionary?; let result = script.executeAndReturnError(&error); if let error { throw AdapterError.automation(error[NSAppleScript.errorMessage] as? String ?? "Apple Events error") }; return result }
    private func escaped(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    private func notesOnScreen() -> Bool { guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first, !app.isHidden else { return false }; return (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).contains { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 } }
}
