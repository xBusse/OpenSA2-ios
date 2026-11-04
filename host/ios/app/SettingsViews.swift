// SettingsViews.swift: display and speed, tweaks, and saves.
import SwiftUI
import UniformTypeIdentifiers

struct DisplaySettingsView: View {
    @EnvironmentObject var s: GameSettings

    var body: some View {
        let (lng, shrt) = Launcher.shared.screenPixels
        List {
            Section(header: Text("Screen"), footer: Text(footer(lng, shrt))) {
                Picker("Orientation", selection: $s.orientation) {
                    ForEach(Orientation.allCases) { Text($0.label).tag($0) }
                }
                if s.orientation == .landscape {
                    Toggle("Widescreen", isOn: $s.widescreen)
                    if s.widescreen {
                        Picker("Aspect", selection: $s.aspect) {
                            ForEach(GameSettings.aspects, id: \.self) { Text($0 == "auto" ? "The screen's" : $0).tag($0) }
                        }
                    }
                }
                if s.fixed43 || s.widescreen {
                    Picker("Resolution", selection: $s.resolution) {
                        ForEach(GameSettings.resolutions, id: \.self) { lines in
                            Text(label(lines, lng, shrt)).tag(lines)
                        }
                    }
                }
                Toggle("HUD at 4:3 positions", isOn: $s.hud43)
                if s.orientation != .landscape {
                    VStack(alignment: .leading) {
                        Text("Picture position upright: \(s.pictureY)% down")
                        Slider(value: Binding(get: { Double(s.pictureY) }, set: { s.pictureY = Int($0) }), in: 0...50, step: 1)
                    }
                }
            }
            Section(header: Text("Speed"),
                    footer: Text("On a slow device: draw stage frames at 30 or 20 a second, the game's speed kept (runtime/sa2_frameskip.c). Auto picks 1 to 3 game ticks a frame as the game runs.")) {
                Picker("Low-FPS speed fix", selection: $s.frameskip) {
                    Text("Off").tag("off"); Text("30 frames a second").tag("30")
                    Text("20 frames a second").tag("20"); Text("Auto").tag("auto")
                }
            }
            Section(header: Text("Sound")) {
                Toggle("Sound", isOn: $s.audio)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Display and speed")
    }

    private func label(_ lines: Int, _ lng: Int, _ shrt: Int) -> String {
        guard let p = s.picture(lng, shrt, lines: lines) else { return lines == 0 ? "The config's (1280x720)" : "\(lines) lines" }
        return lines == 0 ? "Full (\(p.0)x\(p.1))" : "\(p.0)x\(p.1)"
    }

    private func footer(_ lng: Int, _ shrt: Int) -> String {
        if let p = s.picture(lng, shrt) { return "The game draws at \(p.0)x\(p.1). Portrait and rotating always draw 4:3, the game's menus' own shape." }
        return "The game draws at its config's own size, 1280x720, pillarboxed."
    }
}

struct TweaksView: View {
    @EnvironmentObject var s: GameSettings
    @State private var open: String?

    var body: some View {
        List {
            if let p = Tweaks.shared.problem { Section { Text(p).foregroundColor(.orange) } }
            Section(footer: Text("Every tweak is off until you turn it on, and replays never use them. Tweaks that patch the game's code work only where the build linked them; the game's log names any it was built without.")) {
                Button("Turn every tweak off") { s.tweaksOn = [] }.disabled(s.tweaksOn.isEmpty)
            }
            ForEach(Tweaks.shared.groups) { g in
                Section(header: Text(g.heading)) {
                    ForEach(g.tweaks) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(t.label, isOn: Binding(get: { s.tweaksOn.contains(t.name) },
                                                          set: { on in if on { s.tweaksOn.insert(t.name) } else { s.tweaksOn.remove(t.name) } }))
                            if open == t.name {
                                Text(t.description).font(.footnote).foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { open = open == t.name ? nil : t.name }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tweaks")
    }
}

struct SavesView: View {
    @EnvironmentObject var model: AppModel
    @State private var importing = false

    var body: some View {
        List {
            Section(footer: Text("The game's saves live in the app's own data, beside the game folder, which is never written. Export copies them into the app's folder in the Files app; import copies a folder of save files over them.")) {
                Button("Export saves") { model.exportSaves() }.disabled(model.install == .missing)
                Button("Import saves from a folder…") { importing = true }.disabled(model.install != .ready)
            }
            if !model.overlay.isEmpty {
                Section(header: Text("Where they are")) {
                    Text(model.overlay).font(.caption2).foregroundColor(.secondary).textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Saves")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { model.importSaves(from: url) }
        }
        .alert(item: Binding(get: { model.notice.map { Notice(text: $0) } }, set: { _ in model.notice = nil })) { n in
            Alert(title: Text(n.text))
        }
    }
}
