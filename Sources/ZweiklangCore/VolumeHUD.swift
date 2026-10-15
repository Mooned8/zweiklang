import AppKit
import SwiftUI

/// Small on-screen display after a volume key press, also above full-screen films.
@MainActor
public final class VolumeHUD {
    private let controller: SessionController
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    /// Bumped on every show, so a fade-out that is already running cannot hide a newer display.
    private var generation = 0

    public init(controller: SessionController) {
        self.controller = controller
    }

    public func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 16))
        }
        generation += 1
        let token = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0 // stops a running fade-out
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel?.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if self?.generation == token { panel?.orderOut(nil) }
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: VolumeHUDView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 104)
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

struct VolumeHUDView: View {
    let controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<SessionController.slotCount, id: \.self) { slot in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "airpods.pro")
                        Text(verbatim: controller.displayName(slot: slot)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if controller.isMuted {
                            Image(systemName: "speaker.slash.fill")
                        } else {
                            Text(verbatim: "\(Int((controller.volumes[slot] * 100).rounded())) %").monospacedDigit()
                        }
                    }
                    .font(.callout)
                    LevelBar(value: CGFloat(controller.isMuted ? 0 : controller.volumes[slot]))
                }
            }
        }
        .padding(14)
        .frame(width: 280, height: 104)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Always-visible bar; a ProgressView turns grey in a panel that never becomes key.
private struct LevelBar: View {
    let value: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(.primary).frame(width: max(0, min(1, value)) * geometry.size.width)
            }
        }
        .frame(height: 6)
    }
}
