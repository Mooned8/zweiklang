import AppKit
import SwiftUI

/// The window that opens from the menu bar icon.
public struct MenuContentView: View {
    @Bindable var controller: SessionController
    let options: AppOptions
    let onQuit: () -> Void
    @State private var showsTiming = false

    public init(controller: SessionController, options: AppOptions, onQuit: @escaping () -> Void) {
        self.init(controller: controller, options: options, onQuit: onQuit, showsTiming: false)
    }

    init(controller: SessionController, options: AppOptions, onQuit: @escaping () -> Void, showsTiming: Bool) {
        self.controller = controller
        self.options = options
        self.onQuit = onQuit
        _showsTiming = State(initialValue: showsTiming)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if controller.phase == .active {
                activeSection
            } else {
                setupSection
            }
            if options.mediaKeysEnabled && !options.mediaKeysReady {
                Notice(
                    text: L("To use the volume keys, Zweiklang needs your permission under Accessibility."),
                    systemImage: "keyboard",
                    action: (L("Allow …"), { options.requestMediaKeyPermission() })
                )
            }
            if let error = options.launchAtLoginError {
                Notice(text: error, systemImage: "exclamationmark.triangle.fill")
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            controller.refresh()
            options.refresh()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "airpods.pro")
                .font(.system(size: 18))
                .foregroundStyle(controller.phase == .active ? Color.accentColor : .secondary)
            Text(verbatim: "Zweiklang").font(.headline)
            Spacer()
            if controller.phase == .active && controller.isSelectedAsOutput {
                T("Active")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                T("Outputs").font(.caption).foregroundStyle(.secondary)
                ForEach(controller.targets.indices, id: \.self, content: slotRow)
                addOutputMenu
            }
            if controller.hasManyBluetoothOutputs {
                Notice(text: L("More than two Bluetooth headphones on one Mac can cause dropouts."),
                       systemImage: "antenna.radiowaves.left.and.right")
            }
            if case .failed(let message) = controller.phase {
                Notice(text: message, systemImage: "exclamationmark.triangle.fill")
            }
            Button {
                Task { await controller.start() }
            } label: {
                HStack(spacing: 8) {
                    if case .working(let step) = controller.phase {
                        ProgressView().controlSize(.small)
                        Text(verbatim: step)
                    } else {
                        T("Listen together")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(controller.isBusy || !controller.canStart)
            if controller.isWorking {
                Button { controller.stop() } label: { T("Cancel") }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func slotRow(_ slot: Int) -> some View {
        HStack(spacing: 6) {
            slotPicker(slot)
            if controller.targets.count > SessionController.minimumSlots {
                Button { controller.removeOutput(slot: slot) } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!controller.canEditOutputs)
                .help(T("Remove output"))
                .accessibilityLabel(T("Remove output"))
            }
        }
    }

    private var addOutputMenu: some View {
        let addable = controller.addableTargets
        let bluetooth = addable.filter { $0.bluetoothAddress != nil }
        let others = addable.filter { $0.bluetoothAddress == nil }
        return Menu {
            if !bluetooth.isEmpty {
                Section {
                    ForEach(bluetooth) { target in Button(target.name) { controller.addOutput(target) } }
                } header: {
                    T("Bluetooth")
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { target in Button(target.name) { controller.addOutput(target) } }
                } header: {
                    T("Other outputs")
                }
            }
        } label: {
            Label { T("Add output") } icon: { Image(systemName: "plus") }
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(addable.isEmpty || !controller.canEditOutputs)
    }

    private func slotPicker(_ slot: Int) -> some View {
        let connected = controller.slotDevices[slot] != nil
        let selection = Binding<String?>(
            get: { controller.targets[slot]?.id },
            set: { id in controller.select(controller.candidates.first { $0.id == id }, slot: slot) }
        )
        let bluetooth = controller.candidates.filter { $0.bluetoothAddress != nil }
        let others = controller.candidates.filter { $0.bluetoothAddress == nil }
        // A menu with its own label: a plain Picker does not stretch to the full width on macOS.
        return Menu {
            Picker(selection: selection) {
                T("Please choose").tag(String?.none)
                if !bluetooth.isEmpty {
                    Section {
                        ForEach(bluetooth) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                    } header: {
                        T("Bluetooth")
                    }
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                    } header: {
                        T("Other outputs")
                    }
                }
            } label: {
                Text(verbatim: controller.displayName(slot: slot))
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(connected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                (controller.targets[slot].map { Text(verbatim: $0.name) } ?? T("Please choose"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(controller.targets[slot] == nil ? .secondary : .primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(controller.isBusy)
        .help(connected ? T("Connected") : T("Not connected"))
        .accessibilityLabel(Text(verbatim: controller.displayName(slot: slot)))
        .accessibilityValue(connected ? T("Connected") : T("Not connected"))
    }

    // MARK: Active session

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !controller.isSelectedAsOutput {
                Notice(
                    text: L("The sound is currently playing on another device."),
                    systemImage: "speaker.slash.fill",
                    action: (L("Bring it back"), { controller.selectAsOutput() })
                )
            }
            if let message = controller.message {
                Notice(text: message, systemImage: "exclamationmark.triangle.fill",
                       action: (L("Hide"), { controller.dismissMessage() }))
            }
            if controller.hasManyBluetoothOutputs {
                Notice(text: L("More than two Bluetooth headphones on one Mac can cause dropouts."),
                       systemImage: "antenna.radiowaves.left.and.right")
            }
            scrollingIfTall(estimatedHeight: outputControlsHeight) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(controller.chosenSlots, id: \.self, content: volumeRow)
                    HStack {
                        Label { T("Link sliders") } icon: { Image(systemName: "link") }.font(.callout)
                        Spacer()
                        Toggle(isOn: $controller.linked) { T("Link sliders") }
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    timingSection
                }
            }
            Button {
                controller.stop()
            } label: {
                T("Stop listening together").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private func volumeRow(_ slot: Int) -> some View {
        let connected = controller.slotDevices[slot] != nil
        let volume = Binding<Float>(
            get: { controller.volumes[slot] },
            set: { controller.setVolume($0, slot: slot) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: controller.displayName(slot: slot)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if connected {
                    (controller.isMuted ? T("muted") : Text(verbatim: "\(Int((controller.volumes[slot] * 100).rounded())) %"))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if connected {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
                }
                .disabled(!controller.slotHasVolume[slot])
            } else {
                HStack {
                    T("Disconnected").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    if controller.isReconnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await controller.start() } } label: { T("Reconnect") }
                            .controlSize(.small)
                            .disabled(controller.isBusy)
                    }
                }
            }
        }
    }

    // MARK: Timing

    private var timingSection: some View {
        DisclosureGroup(isExpanded: $showsTiming) {
            VStack(alignment: .leading, spacing: 10) {
                T("If an output plays ahead, delay it until the sound is in sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(timingSlots, id: \.self, content: delayRow)
            }
            .padding(.top, 6)
        } label: {
            Label { T("Timing") } icon: { Image(systemName: "timer") }.font(.callout)
        }
    }

    private func delayRow(_ slot: Int) -> some View {
        let delay = Binding<Double>(
            get: { controller.syncOffset(slot: slot) },
            set: { controller.setSyncOffset($0, slot: slot) }
        )
        let automatic = Int(controller.automaticDelays[slot].rounded())
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: controller.displayName(slot: slot)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(verbatim: "+\(Int(controller.syncOffset(slot: slot))) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            // No `step:`, it draws 80 tick marks; the controller snaps to 5 ms.
            Slider(value: delay, in: SyncDelays.manualRange)
                .controlSize(.small)
                .accessibilityLabel(Text(verbatim: controller.displayName(slot: slot)))
                .accessibilityValue(Text(verbatim: "\(Int(controller.syncOffset(slot: slot))) ms"))
            if automatic > 0 {
                Text(verbatim: L("+\(String(automatic)) ms added automatically"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timingSlots: [Int] { controller.chosenSlots.filter { controller.slotDevices[$0] != nil } }

    /// Rough height of the sliders block; rows have fixed layouts, so counting them is enough.
    private var outputControlsHeight: CGFloat {
        var height = CGFloat(controller.chosenSlots.count) * 58 + 40
        if showsTiming {
            height += 50 + timingSlots.reduce(0) { sum, slot in sum + (controller.automaticDelays[slot] >= 0.5 ? 70 : 56) }
        }
        return height
    }

    /// Room for the sliders, keeping header, notices, "Stop" and the footer on the screen.
    private var maximumControlsHeight: CGFloat {
        max(220, (NSScreen.main?.visibleFrame.height ?? 800) - 420)
    }

    /// Many outputs (and the open timing section) would push the buttons below off the screen; then the sliders scroll.
    @ViewBuilder
    private func scrollingIfTall<Content: View>(estimatedHeight: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        if estimatedHeight > maximumControlsHeight {
            ScrollView {
                content().padding(.trailing, 12)
            }
            .frame(height: maximumControlsHeight)
        } else {
            content()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Menu {
                Toggle(isOn: Binding(
                    get: { options.mediaKeysEnabled },
                    set: { options.setMediaKeysEnabled($0) }
                )) { T("Volume keys control all outputs") }
                Toggle(isOn: Binding(
                    get: { options.launchAtLogin },
                    set: { options.setLaunchAtLogin($0) }
                )) { T("Open at login") }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(T("Settings"))
            Spacer()
            Button(action: onQuit) { T("Quit Zweiklang") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }
}

/// Small tinted box for hints and errors, optionally with one button.
private struct Notice: View {
    let text: String
    let systemImage: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: text).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action: action.run) { Text(verbatim: action.title) }.controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
