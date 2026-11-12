import SwiftUI
import AppKit

/// Everything about the monitors themselves: modes, arrangement, hardware
/// controls over DDC, extra XDR brightness, and saved presets.
struct DisplaySettings: View {
    @ObservedObject var modes = DisplayModeController.shared
    @ObservedObject var brightness = BrightnessController.shared
    @ObservedObject var presets = DisplayPresets.shared
    @ObservedObject var xdr = XDRBoost.shared
    @State private var newPresetName = ""
    @State private var ddcValues: [String: Double] = [:]
    @State private var mirroring = DisplayArrangement.isMirroring

    var body: some View {
        Form {
            Section("Presets") {
                ForEach(presets.presets) { preset in
                    HStack(spacing: 10) {
                        GlyphBadge(symbol: "rectangle.on.rectangle", tint: .teal, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name)
                            Text(preset.entries.map(\.name).joined(separator: " + "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Toggle("Auto", isOn: Binding(get: { preset.autoApply },
                                                     set: { presets.setAutoApply($0, for: preset) }))
                            .toggleStyle(.checkbox)
                            .help("Apply whenever exactly these displays are connected")
                        Button("Apply") { presets.apply(preset) }
                        Button(role: .destructive) { presets.delete(preset) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Preset name", text: $newPresetName, prompt: Text("Preset name, e.g. Desk"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveNew)
                    Button("Save current setup", action: saveNew)
                        .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("A preset remembers each display's resolution, refresh rate, brightness and position. "
                   + "With Auto on, plugging into the same set of monitors applies it on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(modes.displays) { display in
                Section(display.name) {
                    modePickers(display)
                    if NSScreen.screens.count > 1 { arrangement(display) }
                    if !display.isBuiltin { hardware(display) }
                }
            }

            if NSScreen.screens.count > 1 || mirroring {
                Section("Arrangement") {
                    Toggle("Mirror displays", isOn: Binding(
                        get: { mirroring },
                        set: { on in
                            DisplayArrangement.setMirroring(on)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                mirroring = DisplayArrangement.isMirroring
                            }
                        }))
                }
            }

            Section("Extra brightness") {
                if xdr.isSupported {
                    Toggle("Boost past 100% (XDR)", isOn: Binding(get: { xdr.isActive }, set: { _ in xdr.toggle() }))
                    if xdr.isActive {
                        LabeledContent("Boost") {
                            Slider(value: $xdr.amount, in: 0...1).frame(width: 220)
                        }
                    }
                    Text("Uses the HDR headroom macOS normally keeps for HDR video. "
                       + "It runs the backlight harder, so it costs battery and heat.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("None of the connected displays has HDR headroom. This works on "
                       + "Liquid Retina XDR MacBook Pros, the Pro Display XDR and HDR monitors.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            modes.refresh()
            for d in modes.displays where !d.isBuiltin { readDDC(d.id) }
        }
    }

    private func saveNew() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        presets.saveCurrent(named: name)
        newPresetName = ""
    }

    // MARK: - Rows

    @ViewBuilder
    private func modePickers(_ d: DisplayModeController.Display) -> some View {
        Picker("Resolution", selection: Binding(
            get: { d.current?.resolution.id ?? "" },
            set: { id in
                if let r = d.resolutions.first(where: { $0.id == id }) { modes.setResolution(r, for: d.id) }
            })) {
            ForEach(d.resolutions) { r in
                let native = r == d.nativeResolution
                Text(r.label + (r.hiDPI ? "  HiDPI" : "") + (native ? "  — native" : "")).tag(r.id)
            }
        }
        Picker("Refresh rate", selection: Binding(
            get: { d.current?.refresh ?? 0 },
            set: { modes.setRefresh($0, for: d.id) })) {
            ForEach(d.refreshRates, id: \.self) { hz in
                Text(DisplayModeController.rateLabel(hz)).tag(hz)
            }
        }
        .disabled(d.refreshRates.count < 2)
    }

    @ViewBuilder
    private func arrangement(_ d: DisplayModeController.Display) -> some View {
        let isMain = CGDisplayIsMain(d.id) != 0
        LabeledContent("Position") {
            HStack {
                if isMain {
                    Label("Main display", systemImage: "menubar.rectangle")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Make main") { DisplayArrangement.makeMain(d.id) }
                    Menu("Place") {
                        ForEach(DisplayArrangement.Side.allCases) { side in
                            Button("\(side.title) of main") { DisplayArrangement.place(d.id, side) }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private func hardware(_ d: DisplayModeController.Display) -> some View {
        if DDC.shared.supports(d.id) {
            ddcSlider("Brightness", "sun.max", .brightness, d.id)
            ddcSlider("Contrast", "circle.lefthalf.filled", .contrast, d.id)
            ddcSlider("Volume", "speaker.wave.2", .volume, d.id)
            Picker("Input", selection: Binding(
                get: { DDC.shared.cached(.input, for: d.id).map { $0.cur & 0xFF } ?? 0 },
                set: { DDC.shared.write(.input, $0, for: d.id) })) {
                Text("—").tag(UInt16(0))
                ForEach(DDC.inputs, id: \.value) { Text($0.name).tag($0.value) }
            }
            Text("Sent straight to the monitor over the cable (DDC/CI), like its own buttons. "
               + "Switching input hands the screen to the other source.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(DDC.shared.isAvailable
                 ? "This monitor isn't answering hardware commands (DDC/CI). It may be off in the monitor's menu, or a dock or adapter is blocking it — brightness uses software dimming instead."
                 : "Hardware control needs Apple Silicon. Brightness uses software dimming.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func ddcSlider(_ title: String, _ symbol: String, _ code: DDC.VCP, _ id: CGDirectDisplayID) -> some View {
        let key = "\(id)-\(code.rawValue)"
        return LabeledContent {
            HStack {
                Slider(value: Binding(
                    get: { ddcValues[key] ?? DDC.shared.cachedLevel(code, for: id) ?? 0.5 },
                    set: { v in
                        ddcValues[key] = v
                        if code == .brightness { brightness.setLevel(v, for: id) }
                        else { DDC.shared.writeLevel(code, v, for: id) }
                    }), in: 0...1)
                .frame(width: 200)
                Text("\(Int((ddcValues[key] ?? DDC.shared.cachedLevel(code, for: id) ?? 0.5) * 100))")
                    .font(Theme.Font.numeric).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func readDDC(_ id: CGDirectDisplayID) {
        for code in [DDC.VCP.brightness, .contrast, .volume, .input] {
            DDC.shared.read(code, for: id) { r in
                guard let r, r.1 > 0 else { return }
                ddcValues["\(id)-\(code.rawValue)"] = Double(r.0) / Double(r.1)
            }
        }
    }
}
