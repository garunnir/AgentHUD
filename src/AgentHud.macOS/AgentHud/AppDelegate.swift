import AppKit

/// Minimal app delegate: the HUD lives in the menu-bar/accessory space (no Dock icon).
/// Window configuration (floating level, title bar chrome, position persistence)
/// happens in WindowConfigurator, attached to the content view.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
