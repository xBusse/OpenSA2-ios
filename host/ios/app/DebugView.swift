// DebugView.swift: what a bug report and a measurement need.
//
//  - Sessions: every session's folder (Documents/Sessions, the newest five), its report, console log
//    and records, each readable here and the whole folder shared as a ZIP.
//  - The session recorder (SA2_RECORD_SESSION=1): the saves and config before and after, the pads'
//    log, as the Android app's Debug card turns it on.
//  - The in-game debug overlay from the start, the menu button, sound and pacing.
//  - The renderer's switches (host/d3d9gpu/d9g_entry.cpp): DXT decoded on the CPU, SDL_gpu's
//    debug mode (its usage checks).
//  - game.env.extra: SA2_ lines that replace the session's own settings (the Android app's file,
//    here in the app's Documents, so the Files app or a Mac can put one there too).
//  - A recorded stream played through the player with no game (the renderer's check on a device).
//  - The app's own log and the last launch's.
import SwiftUI
import UniformTypeIdentifiers

struct DebugView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var s: GameSettings
    @State private var pickingStream = false
    @State private var maxFrames = ""
    @State private var confirmReset = false

    var body: some View {
        List {
            Section(header: Text("Sessions")) {
                NavigationLink("Session folders", destination: SessionsView())
                NavigationLink("The last session's report", destination: TextFileView(title: "last-session.txt",
                    url: model.documents.appendingPathComponent("last-session.txt")))
                Toggle("Record sessions (saves, config, pads)", isOn: $s.recordSessions)
            }
            Section(header: Text("In game"),
                    footer: Text("The menu: the button at the top, or a tap with three fingers. The debug overlay shows the console's last lines and the frames handed on; it takes no touches.")) {
                Toggle("Debug overlay from the start", isOn: $s.debugHud)
                Toggle("Menu button", isOn: $s.menuButton)
                Toggle("Sound", isOn: $s.audio)
                Toggle("Pacing (hold the game to the screen)", isOn: $s.pace)
            }
            Section(header: Text("Renderer"),
                    footer: Text("The renderer is Metal through SDL_gpu, each shader converted from SPIR-V to MSL. Decoding DXT on the CPU tests a GPU without BC textures; SDL_gpu's debug mode checks every call it gets (slower).")) {
                Toggle("Decode DXT textures on the CPU", isOn: $s.gpuNoBC)
                Toggle("SDL_gpu debug mode", isOn: $s.gpuDebug)
            }
            Section(header: Text("Extra settings")) {
                NavigationLink("game.env.extra", destination: ExtraEditorView(url: model.documents.appendingPathComponent("game.env.extra")))
            }
            Section(header: Text("Renderer check"),
                    footer: Text("Plays a recorded stream (.sa2s) through the player with no game. It takes the app's one session: quit and open the app again afterwards.")) {
                TextField("Stop after frames (empty: all)", text: $maxFrames).keyboardType(.numberPad)
                Button("Play a stream file…") { pickingStream = true }
            }
            Section(header: Text("Logs")) {
                NavigationLink("The app's log", destination: TextFileView(title: "app.log", url: model.documents.appendingPathComponent("app.log")))
                NavigationLink("The last launch's log", destination: TextFileView(title: "app.previous.log",
                                                                                   url: model.documents.appendingPathComponent("app.previous.log")))
                NavigationLink("The installer's log", destination: TextFileView(title: "install.log", url: model.documents.appendingPathComponent("install.log")))
                Button("Copy the device's description") { UIPasteboard.general.string = deviceDescription() }
            }
            Section {
                Button("Reset every setting", role: .destructive) { confirmReset = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Debug")
        .fileImporter(isPresented: $pickingStream, allowedContentTypes: [.data]) { r in
            guard case .success(let url) = r else { return }
            _ = url.startAccessingSecurityScopedResource()          // held: the player reads it on its own
            playStream(url.path)
        }
        .alert(isPresented: $confirmReset) {
            Alert(title: Text("Reset every setting?"), message: Text("Display, controls, tweaks and debug settings go back to their defaults. Saves are kept."),
                  primaryButton: .destructive(Text("Reset")) { s.resetAll() }, secondaryButton: .cancel())
        }
    }

    private func playStream(_ path: String) {
        let l = Launcher.shared
        let (lng, shrt) = l.screenPixels
        let upright = s.orientation == .portrait
        l.finish(with: PlayRequest(settings: s.sessionSettings(lng, shrt), orientation: s.orientation.rawValue,
                                   screenW: upright ? shrt : lng, screenH: upright ? lng : shrt,
                                   audio: s.audio, pace: s.pace, stream: path,
                                   maxFrames: maxFrames.isEmpty ? nil : maxFrames,
                                   menuButton: s.menuButton, debugHud: s.debugHud))
    }

    private func deviceDescription() -> String {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let p = ProcessInfo.processInfo
        let info = Bundle.main.infoDictionary ?? [:]
        return """
        SA2 Recompiled \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))
        \(machine), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        memory \(p.physicalMemory / (1 << 20)) MiB, \(p.activeProcessorCount) CPUs, thermal \(p.thermalState.rawValue), low power \(p.isLowPowerModeEnabled)
        settings: \(s.sessionSettings(Launcher.shared.screenPixels.0, Launcher.shared.screenPixels.1).joined(separator: " "))
        """
    }
}

struct SessionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var folders: [URL] = []

    var body: some View {
        List {
            if folders.isEmpty { Text("No sessions yet.").foregroundColor(.secondary) }
            ForEach(folders, id: \.self) { f in
                NavigationLink(destination: SessionView(folder: f)) {
                    VStack(alignment: .leading) {
                        Text(f.lastPathComponent).font(.system(.body, design: .monospaced))
                        Text(firstOutcome(f)).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .onAppear {
            let fm = FileManager.default
            folders = ((try? fm.contentsOfDirectory(at: model.sessionsFolder, includingPropertiesForKeys: nil)) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
    }

    private func firstOutcome(_ f: URL) -> String {
        guard let text = try? String(contentsOf: f.appendingPathComponent("report.txt"), encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n")
        return String(lines.last(where: { $0.hasPrefix("OK") || $0.hasPrefix("FAIL") }) ?? lines.last ?? "")
    }
}

struct SessionView: View {
    let folder: URL
    @State private var files: [URL] = []

    var body: some View {
        List {
            Section {
                Button("Share the session (ZIP)") { AppModel.shareZip(of: folder, from: Launcher.shared.topController) }
            }
            Section(header: Text("Files")) {
                ForEach(files, id: \.self) { f in
                    NavigationLink(f.lastPathComponent, destination: TextFileView(title: f.lastPathComponent, url: f))
                }
            }
        }
        .navigationTitle(folder.lastPathComponent)
        .onAppear {
            let fm = FileManager.default
            let order = ["report.txt", "console.log", "game-end.txt", "player-report.runrec", "d3d9gpu.runrec", "game.runrec"]
            files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { a, b in
                    let ia = order.firstIndex(of: a.lastPathComponent) ?? order.count
                    let ib = order.firstIndex(of: b.lastPathComponent) ?? order.count
                    return ia != ib ? ia < ib : a.lastPathComponent < b.lastPathComponent
                }
        }
    }
}

/// A text file's last 256 KiB, monospaced, selectable, shareable.
struct TextFileView: View {
    let title: String
    let url: URL
    @State private var text = ""

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? "(empty, or not there yet)" : text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { AppModel.share([url], from: Launcher.shared.topController) }) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let h = try? FileHandle(forReadingFrom: url) else { text = ""; return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let from = size > 262_144 ? size - 262_144 : 0
        try? h.seek(toOffset: from)
        let data = (try? h.readToEnd()) ?? Data()
        text = (from > 0 ? "… (the last 256 KiB)\n" : "") + String(decoding: data, as: UTF8.self)
    }
}

struct ExtraEditorView: View {
    let url: URL
    @State private var text = ""
    @Environment(\.presentationMode) var presentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One SA2_K=V setting a line, # for a comment. They replace the session's own settings and the settings screens' (SA2_PLAY_RES=h720, SA2_D3D9GPU_NO_BC=1, SA2_TOUCH_CONTROLS=0 …), as on Android. Each one used is named in the session's report.")
                .font(.footnote).foregroundColor(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                .border(Color.secondary.opacity(0.4))
        }
        .padding()
        .navigationTitle("game.env.extra")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try? FileManager.default.removeItem(at: url)
                    } else {
                        try? text.write(to: url, atomically: true, encoding: .utf8)
                    }
                    presentation.wrappedValue.dismiss()
                }
            }
        }
        .onAppear { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }
}
