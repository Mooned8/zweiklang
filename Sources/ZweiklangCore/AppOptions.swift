import AppKit
import Foundation
import Observation
import ServiceManagement

/// Settings around the session: volume keys and launch at login.
@MainActor
@Observable
public final class AppOptions {
    public private(set) var mediaKeysEnabled: Bool
    /// The volume keys are really taken over: permission granted and the event tap installed.
    public private(set) var mediaKeysReady = false
    public private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    public private(set) var launchAtLoginError: String?

    private let defaults: UserDefaults
    @ObservationIgnored private let keyTap = MediaKeyTap()
    @ObservationIgnored private var trustTimer: Timer?

    public init(defaults: UserDefaults, controller: SessionController) {
        self.defaults = defaults
        self.mediaKeysEnabled = defaults.object(forKey: "mediaKeysEnabled") as? Bool ?? true
        keyTap.handler = { [weak controller] event in
            MainActor.assumeIsolated { controller?.handleMediaKey(event) ?? false }
        }
        keyTap.setEnabled(controller.phase == .active)
        controller.onActiveChange = { [weak self] active in
            MainActor.assumeIsolated { self?.keyTap.setEnabled(active) }
        }
        refresh()
    }

    /// Re-checks permission and autostart; runs when the menu opens and every 2 s while the permission is missing.
    public func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard mediaKeysEnabled else {
            keyTap.stop()
            stopTrustTimer()
            mediaKeysReady = false
            return
        }
        if MediaKeyTap.isTrusted, keyTap.start() {
            mediaKeysReady = true
            stopTrustTimer()
        } else {
            keyTap.stop() // permission revoked, or it belongs to an older build
            mediaKeysReady = false
            startTrustTimer()
        }
    }

    public func setMediaKeysEnabled(_ enabled: Bool) {
        mediaKeysEnabled = enabled
        defaults.set(enabled, forKey: "mediaKeysEnabled")
        refresh()
        if enabled && !mediaKeysReady { requestMediaKeyPermission() }
    }

    /// After a rebuild macOS keeps the old entry in the Accessibility list: switched on, but it no longer
    /// matches this app. Removing it first makes macOS ask again for exactly this build.
    public func requestMediaKeyPermission() {
        var staleEntryRemoved = true
        if !MediaKeyTap.isTrusted, let bundleID = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", bundleID]
            do {
                try reset.run()
                reset.waitUntilExit()
                staleEntryRemoved = reset.terminationStatus == 0
            } catch {
                staleEntryRemoved = false
            }
        }
        MediaKeyTap.requestTrust()
        // Without a fresh entry macOS shows no prompt; then go straight to the right settings page.
        if !staleEntryRemoved,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    private func startTrustTimer() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if MediaKeyTap.isTrusted { self?.refresh() }
            }
        }
    }

    private func stopTrustTimer() {
        trustTimer?.invalidate()
        trustTimer = nil
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLoginError = L("Could not change “Open at login”: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
