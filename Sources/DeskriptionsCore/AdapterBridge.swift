import Foundation

public enum AdapterBridgeError: LocalizedError, Equatable {
    case disconnected(String)
    case timeout
    case incompatible(Int)
    case malformedResponse
    public var errorDescription: String? {
        switch self {
        case .disconnected(let id): return "Browser extension profile \(id) is disconnected."
        case .timeout: return "The browser extension did not respond before the timeout."
        case .incompatible(let version): return "Chromium adapter protocol \(version) is incompatible."
        case .malformedResponse: return "The Chromium adapter returned an invalid response."
        }
    }
}

public struct AdapterCommand: Codable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let requestID: String
    public let operationID: String?
    public let payload: JSONValue?
    public init(type: String, requestID: String = UUID().uuidString, operationID: String? = nil, payload: JSONValue? = nil) {
        self.type = type; self.protocolVersion = 1; self.requestID = requestID
        self.operationID = operationID; self.payload = payload
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil()
        }
    }
}

public struct AdapterResponse: Codable, Sendable {
    public let type: String
    public let requestID: String?
    public let operationID: String?
    public let status: String?
    public let code: String?
    public let message: String?
    public let payload: JSONValue?
}

public struct ExtensionRegistration: Equatable, Sendable {
    public enum Compatibility: String, Equatable, Sendable { case compatible, incompatible, malformed }
    public let hello: ExtensionHello?
    public let browserBundleID: String?
    public let installationID: String?
    public let lastSeen: Date
    public let isConnected: Bool
    public let compatibility: Compatibility
    public init(hello: ExtensionHello?, browserBundleID: String?, installationID: String?, lastSeen: Date, isConnected: Bool, compatibility: Compatibility) {
        self.hello = hello; self.browserBundleID = browserBundleID; self.installationID = installationID
        self.lastSeen = lastSeen; self.isConnected = isConnected; self.compatibility = compatibility
    }
}

public actor FileAdapterBridge {
    public let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(root: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("deskriptions-lab", isDirectory: true)) { self.root = root }

    public func connectedProfiles(maxAge: TimeInterval = 65) -> [ExtensionHello] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let candidates: [(ExtensionHello, Date)] = files.filter { $0.lastPathComponent.hasPrefix("profile-") && $0.pathExtension == "json" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate, Date().timeIntervalSince(modified) <= maxAge,
                  let data = try? Data(contentsOf: url), let hello = try? decoder.decode(ExtensionHello.self, from: data),
                  AdapterCompatibility.evaluate(hello).isCompatible else { return nil }
            return (hello, modified)
        }
        // A service-worker startup race in early builds could write two installation
        // identities for one connection session. Reconnects can also leave a fresh old
        // file briefly. A session is one observation stream, never two profiles.
        var newestBySession: [String: (ExtensionHello, Date)] = [:]
        for candidate in candidates {
            let key = "\(candidate.0.browser):\(candidate.0.sessionID)"
            if (newestBySession[key]?.1 ?? .distantPast) < candidate.1 { newestBySession[key] = candidate }
        }
        var newestByInstallation: [String: (ExtensionHello, Date)] = [:]
        for candidate in newestBySession.values where (newestByInstallation[candidate.0.identityKey]?.1 ?? .distantPast) < candidate.1 {
            newestByInstallation[candidate.0.identityKey] = candidate
        }
        return newestByInstallation.values.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Returns the newest durable observation for every browser-scoped extension
    /// installation, including stale and incompatible registrations. Operational
    /// callers should continue to use `connectedProfiles`; this inventory exists
    /// so diagnostics and Settings do not mistake historical handshakes for live
    /// connections or hide registrations merely because they need attention.
    public func extensionRegistrations(maxAge: TimeInterval = 65, now: Date = Date()) -> [ExtensionRegistration] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var newest: [String: ExtensionRegistration] = [:]
        for url in files where url.lastPathComponent.hasPrefix("profile-") && url.pathExtension == "json" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            let data = try? Data(contentsOf: url)
            let hello = data.flatMap { try? decoder.decode(ExtensionHello.self, from: $0) }
            let compatible = hello.map { AdapterCompatibility.evaluate($0).isCompatible } ?? false
            let compatibility: ExtensionRegistration.Compatibility = hello == nil ? .malformed : compatible ? .compatible : .incompatible
            let connected = compatible && now.timeIntervalSince(modified) >= 0 && now.timeIntervalSince(modified) <= maxAge
            let browser = hello?.browser
            let installation = hello?.installationID
            // Malformed files have no trustworthy identity, so retain each one.
            let key = hello.map(\.identityKey) ?? "malformed|\(url.lastPathComponent)"
            let registration = ExtensionRegistration(hello: hello, browserBundleID: browser, installationID: installation, lastSeen: modified, isConnected: connected, compatibility: compatibility)
            if (newest[key]?.lastSeen ?? .distantPast) < modified { newest[key] = registration }
        }
        return newest.values.sorted {
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return ($0.browserBundleID ?? "") < ($1.browserBundleID ?? "")
        }
    }

    public func connectionIssueCounts(maxAge: TimeInterval = 65) -> (incompatible: Int, malformed: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return (0, 0) }
        var incompatible = 0, malformed = 0
        for url in files where url.lastPathComponent.hasPrefix("profile-") && url.pathExtension == "json" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(modified) <= maxAge else { continue }
            guard let data = try? Data(contentsOf: url), let hello = try? decoder.decode(ExtensionHello.self, from: data) else { malformed += 1; continue }
            if hello.protocolVersion != protocolVersion { incompatible += 1 }
        }
        return (incompatible, malformed)
    }

    public func send(_ command: AdapterCommand, to installationID: String, browserBundleID: String? = nil, timeout: TimeInterval = 12) async throws -> AdapterResponse {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let matches = connectedProfiles().filter { $0.installationID == installationID && (browserBundleID == nil || $0.browser == browserBundleID) }
        guard matches.count == 1, let profile = matches.first else { throw AdapterBridgeError.disconnected(installationID) }
        let scoped = "\(profile.browser)-\(installationID)".map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        let commandURL = root.appendingPathComponent("command-\(String(scoped)).json")
        let resultURL = root.appendingPathComponent("result-\(command.requestID).json")
        try encoder.encode(command).write(to: commandURL, options: .atomic)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: resultURL) {
                try? FileManager.default.removeItem(at: resultURL)
                guard let result = try? decoder.decode(AdapterResponse.self, from: data) else { throw AdapterBridgeError.malformedResponse }
                return result
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        // Do not leave an unacknowledged command for a later extension session to
        // execute.  In particular, a timed-out restore must not unexpectedly open
        // content after Chrome reconnects. Only remove the file when it is still
        // the command from this request; a newer writer may have replaced it.
        if let data = try? Data(contentsOf: commandURL),
           let pending = try? decoder.decode(AdapterCommand.self, from: data),
           pending.requestID == command.requestID {
            try? FileManager.default.removeItem(at: commandURL)
        }
        throw AdapterBridgeError.timeout
    }
}
