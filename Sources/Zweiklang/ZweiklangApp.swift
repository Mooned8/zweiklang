import AppKit
import SwiftUI
import ZweiklangCore

@main
struct ZweiklangApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(controller: appDelegate.controller, options: appDelegate.options) {
                NSApp.terminate(nil)
            }
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    let controller: SessionController

    var body: some View {
        Image(systemName: controller.phase == .active ? "airpods.pro.chargingcase.wireless.fill" : "airpods.pro")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: SessionController
    let options: AppOptions
    private let hud: VolumeHUD

    override init() {
        controller = SessionController(defaults: .standard, bluetooth: BluetoothConnector())
        options = AppOptions(defaults: .standard, controller: controller)
        hud = VolumeHUD(controller: controller)
        super.init()
        controller.onVolumeKeyFeedback = { [weak self] in self?.hud.show() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.recoverOnLaunch()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftUI swallows URLs for menu bar apps; take the Apple Event directly.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// zweiklang://start, zweiklang://stop, zweiklang://toggle – for Shortcuts, Siri or the Terminal.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == "zweiklang" else { return }
        switch url.host {
        case "start": Task { await controller.start() }
        case "stop": controller.stop()
        case "toggle":
            if controller.phase == .active || controller.isBusy { controller.stop() } else { Task { await controller.start() } }
        default: break
        }
    }

    private var isQuitting = false

    /// Quitting waits (briefly) until the guest AirPods are released: macOS drops the link only while the app runs.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateNow } // asked again while waiting: quit right away
        isQuitting = true
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await self.controller.prepareForQuit()
            reply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { reply() } // never let a stuck release block quitting
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop() // also cancels a start in progress
    }
}
