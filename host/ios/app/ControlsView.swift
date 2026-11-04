// ControlsView.swift: the touch controls (size, opacity, places, what each button sends) and the
// buttons of a game controller, as the Android app's settings and layout editor have them.
//
// The touch overlay is the player's (host/player/touch_overlay.h): the settings here reach it as
// SA2_TOUCH_SCALE, SA2_TOUCH_OPACITY, SA2_TOUCH_LAYOUT(_PORTRAIT) and SA2_TOUCH_MAP; a controller's
// buttons as SA2_PAD_MAP (host/player/player.cpp "Gamepads"). Any MFi, Xbox, PlayStation or Switch
// controller iOS pairs is a gamepad to SDL; pressing one of its buttons hides the overlay until the
// next touch.
import SwiftUI

struct ControlsView: View {
    @EnvironmentObject var s: GameSettings

    var body: some View {
        List {
            Section(header: Text("Touch controls")) {
                VStack(alignment: .leading) {
                    Text("Size: \(s.touchSize)%")
                    Slider(value: Binding(get: { Double(s.touchSize) }, set: { s.touchSize = Int($0) }), in: 50...200, step: 5)
                }
                VStack(alignment: .leading) {
                    Text("Opacity: \(s.touchOpacity)%")
                    Slider(value: Binding(get: { Double(s.touchOpacity) }, set: { s.touchOpacity = Int($0) }), in: 0...200, step: 5)
                }
                NavigationLink("Move the controls (landscape)", destination: LayoutEditorView(portrait: false))
                NavigationLink("Move the controls (portrait)", destination: LayoutEditorView(portrait: true))
                Toggle("In-game menu button", isOn: $s.menuButton)
            }
            Section(header: Text("What each on-screen button sends")) {
                ForEach(Array(GameSettings.touchButtons.enumerated()), id: \.offset) { _, b in
                    Picker(b, selection: Binding(get: { GameSettings.sends(s.touchMap, b, own: b) },
                                                 set: { s.touchMap = GameSettings.withSend(s.touchMap, order: GameSettings.touchButtons,
                                                                                           owns: GameSettings.touchButtons, button: b, out: $0) })) {
                        ForEach(GameSettings.outputs, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section(header: Text("A controller's buttons"),
                    footer: Text("By position: SOUTH is the bottom face button (A on Xbox, Cross on PlayStation).")) {
                ForEach(Array(GameSettings.padButtons.enumerated()), id: \.offset) { i, b in
                    Picker(b, selection: Binding(get: { GameSettings.sends(s.padMap, b, own: GameSettings.padDefaults[i]) },
                                                 set: { s.padMap = GameSettings.withSend(s.padMap, order: GameSettings.padButtons,
                                                                                         owns: GameSettings.padDefaults, button: b, out: $0) })) {
                        ForEach(GameSettings.outputs, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section {
                Button("Reset every control setting", role: .destructive) {
                    s.touchSize = 100; s.touchOpacity = 100; s.layoutLandscape = ""; s.layoutPortrait = ""
                    s.touchMap = ""; s.padMap = ""
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Controls")
    }
}

/// The layout editor: the screen as the game will have it, scaled to fit (the picture where the
/// game's will be, the controls at their size and places), each group dragged to a new place.
struct LayoutEditorView: View {
    let portrait: Bool
    @EnvironmentObject var s: GameSettings
    @Environment(\.presentationMode) var presentation
    @State private var layout: TouchLayout?
    @State private var dragging: Int?
    @State private var grab = CGPoint.zero

    private var pixels: (w: Float, h: Float) {
        let (lng, shrt) = Launcher.shared.screenPixels
        return portrait ? (Float(shrt), Float(lng)) : (Float(lng), Float(shrt))
    }

    private func fresh() -> TouchLayout {
        let (lng, shrt) = Launcher.shared.screenPixels
        let f = s.frame(lng, shrt)
        // A portrait layout edited while the game is set to landscape: the 4:3 picture upright play draws.
        let frame = portrait && s.orientation == .landscape ? (4 * shrt / 3, shrt) : f
        return TouchLayout.make(w: pixels.w, h: pixels.h, fw: frame.0, fh: frame.1, scale: Float(s.touchSize) / 100,
                                anchor: portrait ? Float(s.pictureY) / 100 : -1, minTop: 0,
                                landscape: s.layoutLandscape, portrait: s.layoutPortrait)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Drag a control to move it").font(.footnote).foregroundColor(.secondary)
            GeometryReader { geo in
                let k = CGFloat(min(Float(geo.size.width) / pixels.w, Float(geo.size.height) / pixels.h))
                let size = CGSize(width: CGFloat(pixels.w) * k, height: CGFloat(pixels.h) * k)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in draw(ctx, k: k, size: size) }
                        .frame(width: size.width, height: size.height)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in drag(v, k: k) }.onEnded { _ in dragging = nil })
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            HStack {
                Button("Reset") { reset() }
                Spacer()
                Button("Swap sides") { swap() }
                Spacer()
                Button("Save") { save() }.font(.headline)
            }
            .padding(.horizontal)
        }
        .padding()
        .navigationTitle(portrait ? "Portrait layout" : "Landscape layout")
        .onAppear { if layout == nil { layout = fresh() } }
    }

    private func draw(_ ctx: GraphicsContext, k: CGFloat, size: CGSize) {
        guard let l = layout else { return }
        let picture = CGRect(x: 0, y: CGFloat(l.pictureTop) * k, width: size.width,
                             height: CGFloat(l.pictureBottom - l.pictureTop) * k)
        ctx.fill(Path(picture), with: .color(sa2Blue.opacity(0.55)))
        ctx.draw(Text("Game picture").font(.caption).foregroundColor(.white.opacity(0.6)),
                 at: CGPoint(x: picture.midX, y: picture.midY))
        let names = ["Stick", "A B X Y", "START", "LT", "RT"]
        for g in 0..<5 {
            let cx = CGFloat(l.x[g]) * k, cy = CGFloat(l.y[g]) * k
            let hw = CGFloat(l.halfW(g)) * k, hh = CGFloat(l.halfH(g)) * k
            let box = CGRect(x: cx - hw, y: cy - hh, width: 2 * hw, height: 2 * hh)
            let colour = dragging == g ? sa2Gold : Color.white
            switch g {
            case 0:
                ctx.stroke(Path(ellipseIn: box), with: .color(colour.opacity(0.8)), lineWidth: 2)
                ctx.fill(Path(ellipseIn: box.insetBy(dx: hw * 0.55, dy: hh * 0.55)), with: .color(colour.opacity(0.5)))
            case 1:
                let r = CGFloat(0.075 * l.s) * k, d = CGFloat(0.135 * l.s) * k
                for (ox, oy, label) in [(0, d, "A"), (d, 0, "B"), (-d, 0, "X"), (0, -d, "Y")] as [(CGFloat, CGFloat, String)] {
                    let c = CGRect(x: cx + ox - r, y: cy + oy - r, width: 2 * r, height: 2 * r)
                    ctx.stroke(Path(ellipseIn: c), with: .color(colour.opacity(0.8)), lineWidth: 2)
                    ctx.draw(Text(label).font(.system(size: max(8, r * 0.8), weight: .bold)).foregroundColor(colour),
                             at: CGPoint(x: c.midX, y: c.midY))
                }
            default:
                ctx.stroke(Path(roundedRect: box, cornerRadius: hh), with: .color(colour.opacity(0.8)), lineWidth: 2)
                ctx.draw(Text(names[g]).font(.system(size: max(7, hh * 0.9), weight: .semibold)).foregroundColor(colour),
                         at: CGPoint(x: cx, y: cy))
            }
        }
    }

    private func drag(_ v: DragGesture.Value, k: CGFloat) {
        guard var l = layout else { return }
        let px = Float(v.location.x / k), py = Float(v.location.y / k)
        if dragging == nil {
            // The group whose box holds the touch, the smallest first (START and the triggers lie inside no other).
            for g in [2, 3, 4, 0, 1] where abs(px - l.x[g]) <= l.halfW(g) && abs(py - l.y[g]) <= l.halfH(g) {
                dragging = g
                grab = CGPoint(x: CGFloat(px - l.x[g]), y: CGFloat(py - l.y[g]))
                break
            }
        }
        guard let g = dragging else { return }
        l.place(g, px - Float(grab.x), py - Float(grab.y))
        layout = l
    }

    private func reset() {
        guard var l = layout else { return }
        l.x = l.dx
        l.y = l.dy
        layout = l
    }

    private func swap() {
        guard var l = layout else { return }
        for g in [0, 1] { l.place(g, l.ax + l.aw - (l.x[g] - l.ax), l.y[g]) }
        layout = l
    }

    private func save() {
        guard let l = layout else { return }
        if portrait { s.layoutPortrait = l.value() } else { s.layoutLandscape = l.value() }
        presentation.wrappedValue.dismiss()
    }
}
