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
        let height = VolumeHUDView.height(rows: controller.chosenSlots.count)
        if panel.frame.height != height {
            panel.setContentSize(NSSize(width: VolumeHUDView.width, height: height))
        }
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
        host.frame = NSRect(x: 0, y: 0, width: VolumeHUDView.width, height: VolumeHUDView.height(rows: SessionController.minimumSlots))
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

    static let width: CGFloat = 280
    private static let rowHeight: CGFloat = 33
    private static let spacing: CGFloat = 10
    private static let padding: CGFloat = 14

    /// Fixed height per row, so the panel can be sized before SwiftUI lays it out.
    static func height(rows: Int) -> CGFloat {
        let rows = CGFloat(max(rows, 1))
        return rows * rowHeight + (rows - 1) * spacing + 2 * padding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(controller.chosenSlots, id: \.self) { slot in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: controller.targets[slot]?.bluetoothAddress != nil ? "airpods.pro" : "hifispeaker")
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
                .frame(height: Self.rowHeight)
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width, height: Self.height(rows: controller.chosenSlots.count))
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
