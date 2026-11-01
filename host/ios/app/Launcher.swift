// Launcher.swift: the app's own screens, shown before and after the session.
//
// SDL owns the app (host/ios/native/sa2_ios_main.mm): its main calls sa2ios_launcher_run, which puts
// the SwiftUI screens in a UIWindow of SDL's scene and turns the main run loop until the user starts
// a session; the session's player then makes SDL's window. After the session,
// sa2ios_launcher_after_session shows its report until the user quits. Both turn the run loop in its
// default mode, as SDL's own message boxes do, so UIKit and SwiftUI run as usual inside them.
import SwiftUI
import UIKit

final class Launcher {
    static let shared = Launcher()

    let model = AppModel()
    let settings = GameSettings()
    private var window: UIWindow?
    private(set) var request: PlayRequest?
    private var done = false

    func show() {
        if window == nil {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
            let root = RootView().environmentObject(model).environmentObject(settings)
            w.rootViewController = UIHostingController(rootView: root)
            w.windowLevel = .normal
            window = w
        }
        window?.isHidden = false
        window?.makeKeyAndVisible()
    }

    func hide() {
        window?.isHidden = true
    }

    var topController: UIViewController? {
        var vc = window?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    /// Turns the main run loop until `finish` is called.
    func spin() {
        done = false
        while !done {
            autoreleasepool { _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, true) }
        }
    }

    func finish(with request: PlayRequest?) {
        self.request = request
        done = true
    }

    /// The screen size in pixels, long side first (UIScreen's native bounds are portrait).
    var screenPixels: (Int, Int) {
        let b = (window?.windowScene?.screen ?? UIScreen.main).nativeBounds.size
        let a = Int(b.width.rounded()), c = Int(b.height.rounded())
        return (max(a, c), min(a, c))
    }
}

/// What the user asked for: a game session or a stream's playback, with its settings.
struct PlayRequest {
    var settings: [String]
    var orientation: String
    var screenW: Int, screenH: Int
    var audio: Bool, pace: Bool
    var stream: String?
    var maxFrames: String?
    var menuButton: Bool
    var debugHud: Bool
}

// strdup'ed for the session, which reads them once; never freed (one session in the app's life).
private func cstr(_ s: String) -> UnsafePointer<CChar> { UnsafePointer(strdup(s)!) }

@_cdecl("sa2ios_launcher_run")
public func sa2ios_launcher_run(_ out: UnsafeMutablePointer<sa2ios_play_args>) -> Int32 {
    let l = Launcher.shared
    l.model.refresh()
    l.show()
    l.spin()
    guard let r = l.request else { return 0 }
    l.hide()
    let list = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: max(1, r.settings.count))
    for (i, s) in r.settings.enumerated() { list[i] = cstr(s) }
    out.pointee.screen_w = Int32(r.screenW)
    out.pointee.screen_h = Int32(r.screenH)
    out.pointee.orientation = cstr(r.orientation)
    out.pointee.audio = r.audio ? 1 : 0
    out.pointee.pace = r.pace ? 1 : 0
    out.pointee.settings = UnsafePointer(list)
    out.pointee.setting_count = Int32(r.settings.count)
    out.pointee.stream = r.stream.map(cstr)
    out.pointee.max_frames = r.maxFrames.map(cstr)
    out.pointee.menu_button = r.menuButton ? 1 : 0
    out.pointee.debug_hud = r.debugHud ? 1 : 0
    return 1
}

@_cdecl("sa2ios_launcher_after_session")
public func sa2ios_launcher_after_session(_ code: Int32, _ session: UnsafePointer<CChar>?) {
    let l = Launcher.shared
    l.model.sessionEnded(code: Int(code), session: session.map { String(cString: $0) } ?? "")
    l.show()
    while true { l.spin() }          // until Quit, which ends the app
}
