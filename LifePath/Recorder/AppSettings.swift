import Core
import SwiftUI

@MainActor struct AppSettings: DynamicProperty {
    @AppStorage("quality") var quality: Quality = .balanced
    @AppStorage("showsIndicator") var showsIndicator = true
    @AppStorage("deepSleep") var deepSleep = false
    @AppStorage("downloadStreets") var downloadStreets = true   // read by StreetService through UserDefaults
    @AppStorage("streetsOnCellular") var streetsOnCellular = true
    @AppStorage("countCycling") var countCycling = false   // read by the map through UserDefaults
    @AppStorage("onboarded") var onboarded = false
    @AppStorage("paused") var paused = false   // the owner's Pause switch: no tracking at all while on
}
