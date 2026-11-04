// HomeView.swift: the first screen: the game's state, Play, and the way to every other screen.
import SwiftUI
import UniformTypeIdentifiers

let sa2Blue = Color(red: 0x1C / 255.0, green: 0x3F / 255.0, blue: 0x94 / 255.0)
let sa2Night = Color(red: 0x10 / 255.0, green: 0x18 / 255.0, blue: 0x30 / 255.0)
let sa2Gold = Color(red: 1, green: 0xC2 / 255.0, blue: 0x1A / 255.0)

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationView {
            if model.ended != nil { ReportView() } else { HomeView() }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .accentColor(sa2Gold)
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: GameSettings
    @State private var importer: ImportKind?

    enum ImportKind: Identifiable { case folder, zip; var id: Int { self == .folder ? 0 : 1 } }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sonic Adventure 2, recompiled for native platforms.").font(.subheadline)
                    Text("Experimental. You need your own copy of the 2012 PC release.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            if let crashed = model.crashedSession {
                Section(header: Text("The last session did not end")) {
                    Text("The app ended during the session in \((crashed as NSString).lastPathComponent): a crash, or iOS closing the app. Its log is kept.")
                        .font(.footnote)
                    NavigationLink("Open its log", destination: SessionView(folder: URL(fileURLWithPath: crashed)))
                    Button("Dismiss") { model.crashedSession = nil }
                }
            }
            gameSection
            Section {
                Button(action: { play() }) {
                    Label("Play", systemImage: "play.fill").font(.headline)
                }
                .disabled(model.install != .ready)
                Button(action: { play(launchTweaks: GameSettings.chaoLaunch) }) {
                    Label("Chao World", systemImage: "leaf.fill")
                }
                .disabled(model.install != .ready)
            } footer: {
                Text(model.install == .ready
                     ? "A game plays once per app launch: quit the app and open it again to play again."
                     : "Verify the game files first.")
            }
            Section {
                NavigationLink(destination: DisplaySettingsView()) { Label("Display and speed", systemImage: "display") }
                NavigationLink(destination: ControlsView()) { Label("Touch and controllers", systemImage: "gamecontroller") }
                NavigationLink(destination: TweaksView()) { Label("Tweaks", systemImage: "slider.horizontal.3") }
                NavigationLink(destination: SavesView()) { Label("Saves", systemImage: "externaldrive") }
                NavigationLink(destination: DebugView()) { Label("Debug", systemImage: "ladybug") }
                NavigationLink(destination: AboutView()) { Label("About", systemImage: "info.circle") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("SA2 Recompiled")
        .onAppear { model.refresh() }
        .fileImporter(isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
                      allowedContentTypes: importer == .zip ? [.zip] : [.folder]) { result in
            let kind = importer
            importer = nil
            guard case .success(let url) = result else { return }
            if kind == .zip {
                let scoped = url.startAccessingSecurityScopedResource()
                model.verify(kind: "zip", path: url.path)
                // The installer copies the archive's files out; the access lasts the app's life.
                _ = scoped
            } else {
                model.pick(folder: url)
            }
        }
    }

    private var gameSection: some View {
        Section(header: Text("The game")) {
            HStack {
                Image(systemName: model.install == .ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(model.install == .ready ? .green : .orange)
                VStack(alignment: .leading) {
                    Text(model.install == .ready ? "Ready" : model.install == .missing ? "Not installed" : "Verify again")
                        .font(.headline)
                    Text(model.install == .ready ? model.gameFolder : model.installWhy)
                        .font(.caption).foregroundColor(.secondary).lineLimit(3)
                }
            }
            if let found = model.foundGame {
                Button(action: { model.verify(kind: "folder", path: found) }) {
                    Label("Verify the game in the Game folder", systemImage: "checkmark.shield")
                }
                .disabled(model.verifying)
            } else {
                Text("Copy your game into On My iPhone › SA2 Recompiled › Game with the Files app (or a Mac's Finder), then come back here.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Button(action: { importer = .folder }) { Label("Choose a folder elsewhere…", systemImage: "folder") }
                .disabled(model.verifying)
            Button(action: { importer = .zip }) { Label("Install from a ZIP of the folder…", systemImage: "doc.zipper") }
                .disabled(model.verifying)
            if model.verifying {
                HStack { ProgressView(); Text("Verifying every file the game reads…").font(.footnote) }
            }
            if let code = model.verifyCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppModel.verdict(code)).font(.footnote).foregroundColor(code == 0 ? .green : .orange)
                    NavigationLink("The installer's log", destination: TextFileView(title: "install.log",
                                                                                    url: model.documents.appendingPathComponent("install.log")))
                        .font(.footnote)
                }
            }
        }
    }

    private func play(launchTweaks: [String] = []) {
        let l = Launcher.shared
        let (lng, shrt) = l.screenPixels
        let upright = settings.orientation == .portrait
        let req = PlayRequest(settings: settings.sessionSettings(lng, shrt, launchTweaks: launchTweaks),
                              orientation: settings.orientation.rawValue,
                              screenW: upright ? shrt : lng, screenH: upright ? lng : shrt,
                              audio: settings.audio, pace: settings.pace, stream: nil, maxFrames: nil,
                              menuButton: settings.menuButton, debugHud: settings.debugHud)
        l.finish(with: req)
    }
}

struct Notice: Identifiable { let text: String; var id: String { text } }

// ------------------------------------------------------------ after a session

struct ReportView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            if let e = model.ended {
                Section {
                    Label(e.code == 0 ? "The session ended" : "The session ended with code \(e.code)",
                          systemImage: e.code == 0 ? "flag.checkered" : "exclamationmark.triangle")
                    Text("To play again, quit the app and open it again: the game runs once per launch.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Section(header: Text("Report")) {
                    Text(model.reportText).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
                if !e.session.isEmpty {
                    Section {
                        NavigationLink("The session's files", destination: SessionView(folder: URL(fileURLWithPath: e.session)))
                        Button("Share the session (ZIP)") {
                            AppModel.shareZip(of: URL(fileURLWithPath: e.session), from: Launcher.shared.topController)
                        }
                    }
                }
            }
            Section {
                Button(role: .destructive) { exit(0) } label: { Label("Quit", systemImage: "power") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Session")
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                Text("OpenSA2 translates the 2012 PC release of Sonic Adventure 2 into native code at build time and supplies a new runtime for graphics, sound, input and operating-system services. This iOS port runs that game on a thread of the app, draws it with Metal through SDL, and plays it with on-screen touch controls or a game controller.")
                    .font(.footnote)
                Text("OpenSA2 is an independent project, not affiliated with SEGA or Sonic Team. Sonic Adventure 2 and its assets belong to their rights holders. The app holds none of them: the game is your own copy.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section(header: Text("Licences")) {
                Text("OpenSA2: GPL-3.0-only. SDL (patched: patches/sdl3), SDL_shadercross, SPIRV-Cross, DXVK's shader compiler and dxbc-spirv, Remill, LLVM, zlib, libpng and zstd keep their own licences (THIRD_PARTY_NOTICES.md).")
                    .font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("About")
    }
}
