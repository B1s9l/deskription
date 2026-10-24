import AppKit

@main
final class DisposableApplication: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    static func main() {
        let app = NSApplication.shared
        let delegate = DisposableApplication()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 220, y: 220, width: 420, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Disposable Deskriptions Test App"
        let label = NSTextField(labelWithString: "Disposable application-only restoration fixture")
        label.frame = NSRect(x: 40, y: 100, width: 340, height: 24)
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
