// AppModel.swift: the app's state between its screens and the native side (sa2_ios_session.h).
import Foundation
import SwiftUI
import UIKit

enum InstallState { case missing, ready, stale }

final class AppModel: ObservableObject {
    let documents: URL
    let gameDropFolder: URL           // Documents/Game: where the Files app puts the game
    let sessionsFolder: URL

    @Published var install: InstallState = .missing
    @Published var installWhy = ""
    @Published var gameFolder = ""
    @Published var overlay = ""
    @Published var foundGame: String?             // a game folder found under Documents/Game
    @Published var pickedFolder: URL?             // a folder chosen elsewhere (kept by a bookmark)
    @Published var verifying = false
    @Published var verifyCode: Int?
    @Published var verifyLog = ""
    @Published var crashedSession: String?
    @Published var ended: (code: Int, session: String)?
    @Published var notice: String?

    init() {
        let fm = FileManager.default
        documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        gameDropFolder = documents.appendingPathComponent("Game", isDirectory: true)
        sessionsFolder = documents.appendingPathComponent("Sessions", isDirectory: true)
        restorePickedFolder()
        var buf = [CChar](repeating: 0, count: 4096)
        sa2ios_crashed_session(&buf, buf.count)
        let crashed = String(cString: buf)
        crashedSession = crashed.isEmpty ? nil : crashed
    }

    func refresh() {
        var game = [CChar](repeating: 0, count: 4096), overlay = [CChar](repeating: 0, count: 4096)
        var why = [CChar](repeating: 0, count: 1024)
        let s = sa2ios_install_status(&game, game.count, &overlay, overlay.count, &why, why.count)
        install = s == 1 ? .ready : s == 0 ? .missing : .stale
        gameFolder = String(cString: game)
        self.overlay = String(cString: overlay)
        installWhy = String(cString: why)
        var found = [CChar](repeating: 0, count: 4096)
        foundGame = sa2ios_find_game_folder(gameDropFolder.path, &found, found.count) == 1 ? String(cString: found) : nil
    }

    // ------------------------------------------------------------ a folder chosen elsewhere

    private static let bookmarkKey = "picked_game_folder"

    private func restorePickedFolder() {
        guard let data = UserDefaults.standard.data(forKey: AppModel.bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            // Held for the app's life: the game reads the folder on its own thread while it plays.
            _ = url.startAccessingSecurityScopedResource()
            pickedFolder = url
            if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: AppModel.bookmarkKey) }
        }
    }

    func pick(folder url: URL) {
        pickedFolder?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData() { UserDefaults.standard.set(data, forKey: AppModel.bookmarkKey) }
        pickedFolder = url
        var found = [CChar](repeating: 0, count: 4096)
        let path = sa2ios_find_game_folder(url.path, &found, found.count) == 1 ? String(cString: found) : url.path
        verify(kind: "folder", path: path)
    }

    // ------------------------------------------------------------ the installer

    func verify(kind: String, path: String) {
        guard !verifying else { return }
        verifying = true
        verifyCode = nil
        verifyLog = ""
        let log = documents.appendingPathComponent("install.log").path
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = Int(sa2ios_install(kind, path, log))
            let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            DispatchQueue.main.async {
                self.verifying = false
                self.verifyCode = rc
                self.verifyLog = text
                self.refresh()
            }
        }
    }

    static func verdict(_ code: Int) -> String {
        switch code {
        case 0: return "Verified. The game is ready to play."
        case 3: return "Refused: a file the game reads is missing or changed, or an extra file would be read unverified. The log names each."
        case 4: return "No game found there: choose the folder that holds sonic2app.exe and resource/."
        case 5: return "A file could not be read or written. The log says which."
        case 6: return "More than one game was found: choose one folder."
        default: return "The installer stopped with code \(code). The log says why."
        }
    }

    // ------------------------------------------------------------ after a session

    func sessionEnded(code: Int, session: String) {
        ended = (code, session)
    }

    var reportText: String {
        var buf = [CChar](repeating: 0, count: 4096)
        sa2ios_report_path(&buf, buf.count)
        return (try? String(contentsOfFile: String(cString: buf), encoding: .utf8)) ?? "(no report)"
    }

    // ------------------------------------------------------------ saves

    func exportSaves() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dest = documents.appendingPathComponent("Saves Export \(f.string(from: Date()))", isDirectory: true)
        var why = [CChar](repeating: 0, count: 1024)
        let n = sa2ios_export_saves(dest.path, &why, why.count)
        notice = n < 0 ? "Export failed: \(String(cString: why))"
                       : "\(n) save file\(n == 1 ? "" : "s") copied to \(dest.lastPathComponent) in the app's folder (Files app)."
    }

    func importSaves(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var why = [CChar](repeating: 0, count: 1024)
        let n = sa2ios_import_saves(url.path, &why, why.count)
        notice = n < 0 ? "Import failed: \(String(cString: why))"
                       : "\(n) save file\(n == 1 ? "" : "s") imported. The game sees them at its next start."
    }

    // ------------------------------------------------------------ sharing

    /// A ZIP of `folder` (the system's own, NSFileCoordinator's upload form), shared from `from`.
    static func shareZip(of folder: URL, from vc: UIViewController?) {
        var err: NSError?
        var copy: URL?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &err) { zip in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(folder.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zip, to: dest)) != nil { copy = dest }
        }
        guard let url = copy else { return }
        share([url], from: vc)
    }

    static func share(_ items: [Any], from vc: UIViewController?) {
        guard let vc = vc else { return }
        let a = UIActivityViewController(activityItems: items, applicationActivities: nil)
        a.popoverPresentationController?.sourceView = vc.view
        a.popoverPresentationController?.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
        vc.present(a, animated: true)
    }
}
