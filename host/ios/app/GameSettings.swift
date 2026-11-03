// GameSettings.swift: the settings the iOS app keeps, and what they ask of a session.
//
// A port of the Android app's GameSettings (host/android/java/com/sa2recomp/app/GameSettings.java):
// the same choices, kept under the same names (UserDefaults instead of SharedPreferences), and the
// same rules for the SA2_ settings a session is given (sessionSettings) and for where the touch
// controls go (TouchLayout, host/player/touch_overlay.cpp's layout). Every setting at its default
// asks for nothing, so such a session runs as the launcher's play does.
//
// What only iOS has: sound and pacing (the Android app's debug intent extras), the in-game menu's
// button and debug overlay (host/ios/native/sa2_ios_ingame.h), and the renderer's debug switches
// (host/d3d9gpu/d9g_entry.cpp), which go to the session as settings like the others.
import Foundation

enum Orientation: String, CaseIterable, Identifiable {
    case landscape, portrait, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        case .auto: return "Rotate with the phone"
        }
    }
}

final class GameSettings: ObservableObject {
    static let resolutions = [0, 1440, 1080, 900, 720, 540, 480]
    static let aspects = ["auto", "21:9", "16:9", "4:3"]
    static let frameskips = ["off", "30", "20", "auto"]
    static let touchButtons = ["A", "B", "X", "Y", "START", "LT", "RT"]
    static let padButtons = ["SOUTH", "EAST", "WEST", "NORTH", "LB", "RB", "BACK", "START", "LS", "RS",
                             "UP", "DOWN", "LEFT", "RIGHT"]
    static let padDefaults = ["A", "B", "X", "Y", "LB", "RB", "BACK", "START", "LS", "RS",
                              "UP", "DOWN", "LEFT", "RIGHT"]
    static let outputs = ["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "START", "BACK", "LS", "RS",
                          "UP", "DOWN", "LEFT", "RIGHT", "NONE"]
    static let configW = 1280, configH = 720
    static let groups = ["STICK", "FACE", "START", "LT", "RT"]
    /// The tweaks the Chao World button turns on for its one launch (the Android app's CHAO_LAUNCH).
    static let chaoLaunch = ["skip-intro", "start-in-chao-world"]

    private let d = UserDefaults.standard

    @Published var orientation: Orientation { didSet { d.set(orientation.rawValue, forKey: "orientation") } }
    @Published var widescreen: Bool { didSet { d.set(widescreen, forKey: "widescreen") } }
    @Published var hud43: Bool { didSet { d.set(hud43, forKey: "hud43") } }
    @Published var resolution: Int { didSet { d.set(resolution, forKey: "resolution") } }
    @Published var aspect: String { didSet { d.set(aspect, forKey: "aspect") } }
    @Published var frameskip: String { didSet { d.set(frameskip, forKey: "frameskip") } }
    @Published var touchSize: Int { didSet { d.set(touchSize, forKey: "touch_size") } }
    @Published var touchOpacity: Int { didSet { d.set(touchOpacity, forKey: "touch_opacity") } }
    @Published var pictureY: Int { didSet { d.set(pictureY, forKey: "picture_y") } }
    @Published var layoutLandscape: String { didSet { d.set(layoutLandscape, forKey: "touch_layout") } }
    @Published var layoutPortrait: String { didSet { d.set(layoutPortrait, forKey: "touch_layout_portrait") } }
    @Published var touchMap: String { didSet { d.set(touchMap, forKey: "touch_map") } }
    @Published var padMap: String { didSet { d.set(padMap, forKey: "pad_map") } }
    @Published var tweaksOn: Set<String> { didSet { d.set(Array(tweaksOn).sorted(), forKey: "tweaks_on") } }
    @Published var recordSessions: Bool { didSet { d.set(recordSessions, forKey: "record_sessions") } }
    @Published var recordStream: Bool { didSet { d.set(recordStream, forKey: "record_stream") } }
    // iOS's own.
    @Published var audio: Bool { didSet { d.set(audio, forKey: "audio") } }
    @Published var pace: Bool { didSet { d.set(pace, forKey: "pace") } }
    @Published var menuButton: Bool { didSet { d.set(menuButton, forKey: "menu_button") } }
    @Published var debugHud: Bool { didSet { d.set(debugHud, forKey: "debug_hud") } }
    @Published var gpuNoBC: Bool { didSet { d.set(gpuNoBC, forKey: "gpu_no_bc") } }
    @Published var gpuDebug: Bool { didSet { d.set(gpuDebug, forKey: "gpu_debug") } }

    init() {
        orientation = Orientation(rawValue: d.string(forKey: "orientation") ?? "") ?? .landscape
        widescreen = d.object(forKey: "widescreen") as? Bool ?? true
        hud43 = d.object(forKey: "hud43") as? Bool ?? true
        resolution = d.object(forKey: "resolution") as? Int ?? 0
        aspect = d.string(forKey: "aspect") ?? "auto"
        frameskip = d.string(forKey: "frameskip") ?? "off"
        touchSize = d.object(forKey: "touch_size") as? Int ?? 100
        touchOpacity = d.object(forKey: "touch_opacity") as? Int ?? 100
        pictureY = d.object(forKey: "picture_y") as? Int ?? 25
        layoutLandscape = d.string(forKey: "touch_layout") ?? ""
        layoutPortrait = d.string(forKey: "touch_layout_portrait") ?? ""
        touchMap = d.string(forKey: "touch_map") ?? ""
        padMap = d.string(forKey: "pad_map") ?? ""
        tweaksOn = Set(d.stringArray(forKey: "tweaks_on") ?? [])
        recordSessions = d.object(forKey: "record_sessions") as? Bool ?? false
        recordStream = d.object(forKey: "record_stream") as? Bool ?? false
        audio = d.object(forKey: "audio") as? Bool ?? true
        pace = d.object(forKey: "pace") as? Bool ?? true
        menuButton = d.object(forKey: "menu_button") as? Bool ?? true
        debugHud = d.object(forKey: "debug_hud") as? Bool ?? false
        gpuNoBC = d.object(forKey: "gpu_no_bc") as? Bool ?? false
        gpuDebug = d.object(forKey: "gpu_debug") as? Bool ?? false
    }

    // ------------------------------------------------------------ the picture (as Android's)

    var upright: Bool { orientation == .portrait }
    var fixed43: Bool { orientation != .landscape }
    var displayDefault: Bool { orientation == .landscape && widescreen && resolution == 0 && aspect == "auto" }

    static func ratio(_ aspect: String) -> Double {
        let parts = aspect.split(separator: ":")
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b > 0 else { return 16.0 / 9 }
        return a / b
    }

    func pictureRatio(_ lng: Int, _ shrt: Int) -> Double {
        if fixed43 { return 4.0 / 3 }
        if aspect == "auto" { return max(Double(lng) / Double(shrt), 4.0 / 3) }
        return GameSettings.ratio(aspect)
    }

    func fullPicture(_ lng: Int, _ shrt: Int) -> (Int, Int)? {
        if !fixed43 && !widescreen { return nil }
        let bw = upright ? shrt : lng, bh = upright ? lng : shrt
        let r = pictureRatio(lng, shrt)
        if Double(bw) / Double(bh) > r { return (Int((Double(bh) * r).rounded()), bh) }
        return (bw, Int((Double(bw) / r).rounded()))
    }

    /// The game's back buffer on a lng x shrt screen, nil where the game keeps its config's size.
    func picture(_ lng: Int, _ shrt: Int, lines: Int? = nil) -> (Int, Int)? {
        let lines = lines ?? resolution
        let sessionRule = orientation == .landscape && widescreen && aspect == "auto" && lines == 0
        if sessionRule { return lng * 3 > shrt * 4 ? (lng, shrt) : nil }
        guard let full = fullPicture(lng, shrt) else { return nil }
        var w = full.0, h = full.1
        if lines > 0 && lines < h {
            w = Int((Double(lines) * pictureRatio(lng, shrt)).rounded())
            h = lines
        }
        return (max(320, min(16384, w)), max(320, min(16384, h)))
    }

    func pictureAnchor() -> Float { orientation == .landscape ? -1 : Float(pictureY) / 100 }

    func frame(_ lng: Int, _ shrt: Int) -> (Int, Int) { picture(lng, shrt) ?? (GameSettings.configW, GameSettings.configH) }

    // ------------------------------------------------------------ the session's settings

    private static func fraction(_ percent: Int) -> String { String(format: "%.2f", Double(percent) / 100) }

    /// SA2_TWEAKS's value: the tweaks turned on and `also`, in the catalogue's order.
    func tweaks(also: [String] = []) -> String {
        Tweaks.shared.all.map(\.name).filter { tweaksOn.contains($0) || also.contains($0) }.joined(separator: ",")
    }

    /// The SA2_K=V settings for these choices on a lng x shrt screen (Android's sessionSettings, and
    /// iOS's renderer switches): none at the defaults.
    func sessionSettings(_ lng: Int, _ shrt: Int, launchTweaks: [String] = []) -> [String] {
        var e: [String] = []
        if !displayDefault {
            if let p = picture(lng, shrt) { e.append("SA2_PLAY_RES=\(p.0)x\(p.1)") } else { e.append("SA2_PLAY_RES=off") }
        }
        if !hud43 { e.append("SA2_PLAY_HUD43=0") }
        switch frameskip {
        case "30": e.append("SA2_PLAY_FRAMESKIP=2")
        case "20": e.append("SA2_PLAY_FRAMESKIP=3")
        case "auto": e.append("SA2_PLAY_FRAMESKIP=auto")
        default: break
        }
        if orientation != .landscape { e.append("SA2_PLAYER_PICTURE_Y=" + GameSettings.fraction(pictureY)) }
        if touchSize != 100 { e.append("SA2_TOUCH_SCALE=" + GameSettings.fraction(touchSize)) }
        if touchOpacity != 100 { e.append("SA2_TOUCH_OPACITY=" + GameSettings.fraction(touchOpacity)) }
        if !layoutLandscape.isEmpty { e.append("SA2_TOUCH_LAYOUT=" + layoutLandscape) }
        if !layoutPortrait.isEmpty { e.append("SA2_TOUCH_LAYOUT_PORTRAIT=" + layoutPortrait) }
        if !touchMap.isEmpty { e.append("SA2_TOUCH_MAP=" + touchMap) }
        if !padMap.isEmpty { e.append("SA2_PAD_MAP=" + padMap) }
        let t = tweaks(also: launchTweaks)
        if !t.isEmpty { e.append("SA2_TWEAKS=" + t) }
        if recordSessions { e.append("SA2_RECORD_SESSION=1") }
        if recordStream { e.append("SA2_IOS_STREAM_SAVE=1") }
        if gpuNoBC { e.append("SA2_D3D9GPU_NO_BC=1") }
        if gpuDebug { e.append("SA2_D3D9GPU_DEBUG=1") }
        return e
    }

    // ------------------------------------------------------------ button maps (as Android's)

    static func sends(_ map: String, _ button: String, own: String) -> String {
        for item in map.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0] == button { return String(parts[1]) }
        }
        return own
    }

    static func withSend(_ map: String, order: [String], owns: [String], button: String, out: String) -> String {
        var items: [String] = []
        for (i, b) in order.enumerated() {
            let v = b == button ? out : sends(map, b, own: owns[i])
            if v != owns[i] { items.append("\(b)=\(v)") }
        }
        return items.joined(separator: ",")
    }

    func resetAll() {
        for key in ["orientation", "widescreen", "hud43", "resolution", "aspect", "frameskip", "touch_size",
                    "touch_opacity", "picture_y", "touch_layout", "touch_layout_portrait", "touch_map", "pad_map",
                    "tweaks_on", "record_sessions", "audio", "pace", "menu_button", "debug_hud", "gpu_no_bc", "gpu_debug"] {
            d.removeObject(forKey: key)
        }
        let fresh = GameSettings()
        orientation = fresh.orientation; widescreen = fresh.widescreen; hud43 = fresh.hud43
        resolution = fresh.resolution; aspect = fresh.aspect; frameskip = fresh.frameskip
        touchSize = fresh.touchSize; touchOpacity = fresh.touchOpacity; pictureY = fresh.pictureY
        layoutLandscape = ""; layoutPortrait = ""; touchMap = ""; padMap = ""; tweaksOn = []
        recordSessions = false; recordStream = false; audio = true; pace = true; menuButton = true; debugHud = false
        gpuNoBC = false; gpuDebug = false
    }
}

// ------------------------------------------------------------ the touch layout (as Android's)

/// The touch overlay's layout on a w x h window showing a fw x fh frame: host/player/touch_overlay.cpp
/// layout(), the same arithmetic as the Android app's GameSettings.TouchLayout, so the editor shows the
/// controls where the game will.
struct TouchLayout {
    var below = false, upright = false
    var ax: Float = 0, ay: Float = 0, aw: Float = 0, ah: Float = 0, s: Float = 0
    var pictureTop: Float = 0, pictureBottom: Float = 0
    var x = [Float](repeating: 0, count: 5), y = [Float](repeating: 0, count: 5)
    var dx = [Float](repeating: 0, count: 5), dy = [Float](repeating: 0, count: 5)

    func halfW(_ g: Int) -> Float { g == 0 ? 0.12 * s : g == 1 ? 0.21 * s : g == 2 ? 0.075 * s : 0.09 * s }
    func halfH(_ g: Int) -> Float { g == 0 ? 0.12 * s : g == 1 ? 0.21 * s : g == 2 ? 0.035 * s : 0.04 * s }

    static func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }

    /// SA2_TOUCH_LAYOUT's value, "" when every group is at its own place.
    func value() -> String {
        var moved = false
        for g in 0..<5 { moved = moved || abs(x[g] - dx[g]) > 0.5 || abs(y[g] - dy[g]) > 0.5 }
        if !moved { return "" }
        return (0..<5).map { g in
            String(format: "%@=%.4f,%.4f", GameSettings.groups[g], TouchLayout.clamp01((x[g] - ax) / aw),
                   TouchLayout.clamp01((y[g] - ay) / ah))
        }.joined(separator: ";")
    }

    mutating func place(_ g: Int, _ px: Float, _ py: Float) {
        let hw = min(halfW(g), aw / 2), hh = min(halfH(g), ah / 2)
        x[g] = max(ax + hw, min(ax + aw - hw, px))
        y[g] = max(ay + hh, min(ay + ah - hh, py))
    }

    static func make(w: Float, h: Float, fw: Int, fh: Int, scale: Float, anchor: Float, minTop: Float,
                     landscape: String, portrait: String) -> TouchLayout {
        var l = TouchLayout()
        l.upright = h > w
        let shortSide = min(w, h)
        var s = shortSide * scale
        var top: Float = 0, bottom = h
        if fw > 0 && fh > 0 && Double(w) * Double(fh) <= Double(h) * Double(fw) {
            let ph = min(h, (w * Float(fh) / Float(fw)).rounded())
            if h - ph > 2 {
                top = ((h - ph) / 2).rounded(.down)
                if anchor >= 0 && h > w {
                    top = min(top, max(minTop, (Float(Double(anchor) * Double(h) - Double(ph) / 2.0)).rounded()))
                }
                bottom = top + ph
            }
        }
        l.pictureTop = top
        l.pictureBottom = bottom
        l.below = h - bottom >= 0.30 * shortSide
        l.ax = 0; l.ay = 0; l.aw = w; l.ah = h
        if l.below {
            l.ay = bottom
            l.ah = h - bottom
            s = min(s, l.ah / 0.60)
        }
        l.s = s
        let m = 0.04 * s, R = 0.12 * s, r = 0.075 * s, d = 0.135 * s, ph = 0.035 * s, th = 0.04 * s, tw = 0.09 * s
        l.dx[0] = l.ax + m + 1.6 * R; l.dy[0] = l.ay + l.ah - m - 1.6 * R
        l.dx[1] = l.ax + l.aw - m - d - r; l.dy[1] = l.ay + l.ah - m - d - r
        l.dx[2] = l.ax + l.aw * 0.5; l.dy[2] = l.ay + m + ph
        l.dx[3] = l.ax + m + tw; l.dy[3] = l.ay + m + th
        l.dx[4] = l.ax + l.aw - m - tw; l.dy[4] = l.ay + m + th
        l.x = l.dx
        l.y = l.dy
        let value = l.upright ? portrait : landscape
        for item in value.split(separator: ";") {
            let parts = item.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let g = GameSettings.groups.firstIndex(of: String(parts[0])) else { continue }
            let xy = parts[1].split(separator: ",")
            guard xy.count == 2, let fx = Float(xy[0]), let fy = Float(xy[1]) else { continue }
            l.place(g, l.ax + clamp01(fx) * l.aw, l.ay + clamp01(fy) * l.ah)
        }
        return l
    }
}
