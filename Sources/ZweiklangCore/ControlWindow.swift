import AppKit
import SwiftUI

/// The menu's controls in a normal window: for when the menu bar icon is hidden
/// (full menu bar, notch) and on the very first launch.
@MainActor
public final class ControlWindow {
    private let controller: SessionController
    private let options: AppOptions
    private let onQuit: () -> Void
    private var window: NSWindow?

    public init(controller: SessionController, options: AppOptions, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.options = options
        self.onQuit = onQuit
    }

    public func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = ControlWindowView(controller: controller, options: options, onQuit: onQuit)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Zweiklang"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

struct ControlWindowView: View {
    let controller: SessionController
    let options: AppOptions
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "menubar.arrow.up.rectangle").foregroundStyle(.secondary)
                T("Zweiklang lives in the menu bar: look for the AirPods icon at the top right. If you can't see it because the menu bar is full, open Zweiklang again from Applications or Spotlight to get this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 16)
            MenuContentView(controller: controller, options: options, onQuit: onQuit)
        }
        .frame(width: 300)
    }
}
