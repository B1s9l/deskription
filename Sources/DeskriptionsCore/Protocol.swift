import Foundation

public let protocolVersion = 1
public let requiredAdapterCapabilities: Set<String> = ["inventory.windows", "inventory.tabs", "inventory.fresh"]

public struct Rect: Codable, Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct TabRecord: Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let url: String
    public let active: Bool
    public let pinned: Bool
    public let index: Int
    public let faviconDataURL: String?
    public init(id: Int, title: String, url: String, active: Bool, pinned: Bool = false, index: Int = 0, faviconDataURL: String? = nil) {
        self.id = id; self.title = title; self.url = url; self.active = active; self.pinned = pinned; self.index = index; self.faviconDataURL = faviconDataURL
    }
}

public struct BrowserWindow: Codable, Equatable, Sendable {
    public let extensionWindowID: Int
    public let sessionID: String?
    public let focused: Bool
    public let state: String
    public let bounds: Rect
    public let tabs: [TabRecord]
    public init(extensionWindowID: Int, sessionID: String? = nil, focused: Bool, state: String, bounds: Rect, tabs: [TabRecord]) {
        self.extensionWindowID = extensionWindowID; self.sessionID = sessionID; self.focused = focused
        self.state = state; self.bounds = bounds; self.tabs = tabs
    }
}

public struct ExtensionHello: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let savedStateVersion: Int
    public let installationID: String
    public let sessionID: String
    public let browser: String
    public let browserIdentitySource: String?
    public let capabilities: [String]
    public let windows: [BrowserWindow]
    public let adapterVersion: String?
    public init(type: String = "hello", protocolVersion: Int = 1, savedStateVersion: Int = 1, installationID: String, sessionID: String, browser: String, capabilities: [String], windows: [BrowserWindow], adapterVersion: String? = nil, browserIdentitySource: String? = "native-parent-process-v1") {
        self.type = type; self.protocolVersion = protocolVersion; self.savedStateVersion = savedStateVersion
        self.installationID = installationID; self.sessionID = sessionID; self.browser = browser
        self.capabilities = capabilities; self.windows = windows; self.adapterVersion = adapterVersion; self.browserIdentitySource = browserIdentitySource
    }
}

public extension ExtensionHello {
    /// Browser-scoped connection identity. Extension storage identifiers are not
    /// assumed to be globally unique across Chromium products.
    var identityKey: String { "\(browser)|\(installationID)" }
}

public struct AdapterCompatibility: Equatable, Sendable {
    public let isCompatible: Bool
    public let explanation: String

    public static func evaluate(_ hello: ExtensionHello) -> AdapterCompatibility {
        guard hello.protocolVersion == protocolVersion else {
            return .init(isCompatible: false, explanation: "protocol v\(hello.protocolVersion) is incompatible; app requires v\(protocolVersion)")
        }
        guard hello.browserIdentitySource == "native-parent-process-v1" else {
            return .init(isCompatible: false, explanation: "browser identity was not verified by the native host")
        }
        guard ChromiumBrowser(rawValue: hello.browser) != nil else {
            return .init(isCompatible: false, explanation: "browser is not supported")
        }
        let missing = requiredAdapterCapabilities.subtracting(hello.capabilities).sorted()
        guard missing.isEmpty else {
            return .init(isCompatible: false, explanation: "missing required capabilities: \(missing.joined(separator: ", "))")
        }
        let release = hello.adapterVersion.map { "adapter release v\($0)" } ?? "adapter release unknown"
        return .init(isCompatible: true, explanation: "protocol v\(protocolVersion) compatible · \(release)")
    }
}

public enum ChromiumBrowser: String, CaseIterable, Codable, Sendable {
    case chrome = "com.google.Chrome"
    case brave = "com.brave.Browser"
    case edge = "com.microsoft.edgemac"

    public var displayName: String {
        switch self { case .chrome: return "Google Chrome"; case .brave: return "Brave Browser"; case .edge: return "Microsoft Edge" }
    }
    public var hostTag: String {
        switch self { case .chrome: return "chrome"; case .brave: return "brave"; case .edge: return "edge" }
    }
    public var executablePath: String {
        switch self {
        case .chrome: return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        case .brave: return "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        case .edge: return "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
        }
    }
    public var nativeMessagingDirectory: String {
        switch self {
        case .chrome: return "Library/Application Support/Google/Chrome/NativeMessagingHosts"
        case .brave: return "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
        case .edge: return "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
        }
    }
    public static func displayName(for bundleID: String) -> String { ChromiumBrowser(rawValue: bundleID)?.displayName ?? "Chromium browser" }
}

public struct NativeWindow: Codable, Equatable, Sendable {
    public let windowID: UInt32
    public let ownerPID: Int32
    public let ownerName: String
    public let title: String
    public let bounds: Rect
    public let onScreen: Bool
    public init(windowID: UInt32, ownerPID: Int32, ownerName: String, title: String, bounds: Rect, onScreen: Bool) {
        self.windowID = windowID; self.ownerPID = ownerPID; self.ownerName = ownerName; self.title = title
        self.bounds = bounds; self.onScreen = onScreen
    }
}

public enum MatchStatus: String, Codable, Sendable { case matched, unresolved, ambiguous }
public struct WindowAssociation: Codable, Equatable, Sendable {
    public let browserWindowID: Int
    public let nativeWindowID: UInt32?
    public let status: MatchStatus
    public let reason: String
}

public enum WindowMatcher {
    // Exact geometry is a candidate generator, never a silent tie-breaker. Coordinates are
    // normalized by the caller because Chrome uses top-left and CG uses global display space.
    public static func associate(browser: [BrowserWindow], native: [NativeWindow], tolerance: Double = 3) -> [WindowAssociation] {
        browser.map { b in
            let candidates = native.filter { n in
                abs(n.bounds.x - b.bounds.x) <= tolerance && abs(n.bounds.y - b.bounds.y) <= tolerance &&
                abs(n.bounds.width - b.bounds.width) <= tolerance && abs(n.bounds.height - b.bounds.height) <= tolerance
            }
            if candidates.count == 1 {
                return .init(browserWindowID: b.extensionWindowID, nativeWindowID: candidates[0].windowID, status: .matched, reason: "unique geometry match")
            }
            if candidates.isEmpty {
                return .init(browserWindowID: b.extensionWindowID, nativeWindowID: nil, status: .unresolved, reason: "no native window has matching bounds")
            }
            return .init(browserWindowID: b.extensionWindowID, nativeWindowID: nil, status: .ambiguous, reason: "multiple native windows have matching bounds; user association required")
        }
    }
}

public actor OperationLedger {
    private var completed: [String: String] = [:]
    private var inFlight = Set<String>()
    public init() {}
    public func begin(_ key: String) -> String? {
        if let prior = completed[key] { return prior }
        if inFlight.contains(key) { return "in_progress" }
        inFlight.insert(key); return nil
    }
    public func finish(_ key: String, result: String) { inFlight.remove(key); completed[key] = result }
    public func interrupt(_ key: String) { inFlight.remove(key) }
}

