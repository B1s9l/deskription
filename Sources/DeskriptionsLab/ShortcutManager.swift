import AppKit
import Carbon.HIToolbox

struct ShortcutBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String
}

@MainActor
final class ShortcutManager {
    enum Action: UInt32, CaseIterable { case pin = 1, save = 2, load = 3
        var title: String { switch self { case .pin: return "Pin focused window"; case .save: return "Save Desktop"; case .load: return "Load Desktop" } }
        var defaults: ShortcutBinding { switch self {
        case .pin: return .init(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥P")
        case .save: return .init(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥S")
        case .load: return .init(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥L")
        } }
    }
    private var handler: EventHandlerRef?
    private var refs: [Action: EventHotKeyRef] = [:]
    private(set) var bindings: [Action: ShortcutBinding?] = [:]
    var onAction: ((Action) -> Void)?

    init() {
        for action in Action.allCases {
            if let data = UserDefaults.standard.data(forKey: "shortcut.\(action.rawValue)"), let saved = try? JSONDecoder().decode(ShortcutBinding?.self, from: data) { bindings[action] = saved }
            else { bindings[action] = action.defaults }
        }
    }
    func install() -> String? {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), shortcutEventHandler, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return "Global shortcut handler failed (\(status))." }
        for action in Action.allCases { if let error = register(action, binding: bindings[action] ?? nil) { return error } }
        return nil
    }
    func update(_ action: Action, binding: ShortcutBinding?) -> String? {
        if let binding, bindings.contains(where: { $0.key != action && $0.value == binding }) { return "That shortcut is already used by Deskriptions." }
        let previous = bindings[action] ?? nil
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        if let error = register(action, binding: binding) {
            _ = register(action, binding: previous)
            return error + " The previous shortcut remains active."
        }
        bindings[action] = binding
        if let data = try? JSONEncoder().encode(binding) { UserDefaults.standard.set(data, forKey: "shortcut.\(action.rawValue)") }
        return nil
    }
    func restoreDefaults() -> String? {
        for action in Action.allCases { if let error = update(action, binding: action.defaults) { return error } }
        return nil
    }
    func display(for action: Action) -> String { (bindings[action] ?? nil)?.display ?? "" }
    fileprivate func fire(_ id: UInt32) { if let action = Action(rawValue: id) { onAction?(action) } }
    private func register(_ action: Action, binding: ShortcutBinding?) -> String? {
        guard let binding else { return nil }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: fourCode("DSKP"), id: action.rawValue), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return "\(action.title) could not use \(binding.display) (system error \(status))." }
        refs[action] = ref; return nil
    }
    deinit { for ref in refs.values { UnregisterEventHotKey(ref) }; if let handler { RemoveEventHandler(handler) } }
}

private func fourCode(_ value: String) -> OSType { value.utf8.prefix(4).reduce(0) { ($0 << 8) | OSType($1) } }
private let shortcutEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }; var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue(); Task { @MainActor in manager.fire(id.id) }; return noErr
}

func shortcutFrom(event: NSEvent) -> ShortcutBinding? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var carbon: UInt32 = 0; var marks = ""
    if flags.contains(.control) { carbon |= UInt32(controlKey); marks += "⌃" }
    if flags.contains(.option) { carbon |= UInt32(optionKey); marks += "⌥" }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey); marks += "⇧" }
    if flags.contains(.command) { carbon |= UInt32(cmdKey); marks += "⌘" }
    guard carbon != 0, event.keyCode != UInt16(kVK_Escape) else { return nil }
    let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
    return .init(keyCode: UInt32(event.keyCode), modifiers: carbon, display: marks + key)
}
