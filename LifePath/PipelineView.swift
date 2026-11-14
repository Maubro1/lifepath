import Core
import SwiftUI

struct PipelineView: View {
    private let info = Bundle.main.infoDictionary ?? [:]
    private let launchCount = UserDefaults.standard.integer(forKey: "pipeline.launchCount")

    private var version: String {
        "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    private var signingExpiry: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let date = ProvisioningProfile.expirationDate(from: data)
        else { return "unknown" }
        return date.formatted(.dateTime)
    }

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Version", value: version)
                LabeledContent("Opened", value: "\(launchCount)")
                LabeledContent("Signing expires", value: signingExpiry)
            }
            .navigationTitle("LifePath")
        }
    }
}
