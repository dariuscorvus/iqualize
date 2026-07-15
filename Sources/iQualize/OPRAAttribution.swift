import SwiftUI
import AppKit

/// OPRA attribution, required by the OPRA database's CC BY-SA 4.0 license: any
/// app presenting a browser for the database must show the OPRA logo, a short
/// description of the project, and a link to the repository. Per-preset author
/// credit is shown alongside each curve in the browser.
///
/// See https://github.com/opra-project/OPRA — the `images/` folder holds the
/// logo assets and the README's "How is this repository licensed?" section
/// spells out the attribution requirement.
enum OPRAAttribution {
    static let projectURL = URL(string: "https://github.com/opra-project/OPRA")!

    static let blurb = "OPRA is an open, community-maintained directory of "
        + "product information and EQ compensation curves that optimize a wide "
        + "range of headphone models."

    /// The OPRA wordmark — black line-art on transparent, marked as a template
    /// so it tints to the current foreground color and reads in light or dark.
    static let logo: NSImage? = {
        guard let data = Data(base64Encoded: logoBase64) else { return nil }
        let image = NSImage(data: data)
        image?.isTemplate = true
        return image
    }()

    // opra_logo.png from the OPRA repo, cropped and scaled to 220px wide.
    private static let logoBase64 =
        "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"
        + "AABJRU5ErkJggg=="
}

@available(macOS 14.2, *)
struct OPRAAttributionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let logo = OPRAAttribution.logo {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(height: 20)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("OPRA")
            }
            Text(OPRAAttribution.blurb)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Learn more or contribute", destination: OPRAAttribution.projectURL)
                .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
