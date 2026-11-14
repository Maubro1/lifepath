import Core
import SwiftUI

@MainActor struct AppSettings: DynamicProperty {
    @AppStorage("quality") var quality: Quality = .balanced
    @AppStorage("showsIndicator") var showsIndicator = true
    @AppStorage("deepSleep") var deepSleep = false
    @AppStorage("onboarded") var onboarded = false
}
