// Tweaks.swift: the tweaks the settings screen offers, read from the app's tweaks.json.
//
// tools/s9/ios_app.py writes tweaks.json from the Android app's GameSettings.java (its TWEAKS lines
// and TWEAK_GROUPS headings), so a tweak added the way runtime/sa2_tweaks.h says ("Add a tweak")
// reaches this app with no line here. pause-unfocused is left out: the iOS session always turns it
// on (host/ios/native/sa2_ios_session.mm), since iOS refuses GPU work from an app in the background.
import Foundation

struct Tweak: Identifiable, Decodable, Hashable {
    let name: String
    let label: String
    let description: String
    var id: String { name }
}

struct TweakGroup: Identifiable, Decodable {
    let heading: String
    let tweaks: [Tweak]
    var id: String { heading }
}

final class Tweaks {
    static let shared = Tweaks()
    static let alwaysOn: Set<String> = ["pause-unfocused"]

    let groups: [TweakGroup]
    let all: [Tweak]                 // the catalogue's order: SA2_TWEAKS names them in this order
    let problem: String?

    private init() {
        var groups: [TweakGroup] = []
        var all: [Tweak] = []
        var problem: String?
        struct File: Decodable { let order: [Tweak]; let groups: [TweakGroup] }
        if let url = Bundle.main.url(forResource: "tweaks", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            do {
                let f = try JSONDecoder().decode(File.self, from: data)
                all = f.order.filter { !Tweaks.alwaysOn.contains($0.name) }
                groups = f.groups.map { TweakGroup(heading: $0.heading, tweaks: $0.tweaks.filter { !Tweaks.alwaysOn.contains($0.name) }) }
                    .filter { !$0.tweaks.isEmpty }
            } catch {
                problem = "tweaks.json does not read: \(error)"
            }
        } else {
            problem = "the app was built without tweaks.json"
        }
        self.groups = groups
        self.all = all
        self.problem = problem
    }
}
