import SwiftUI

/// Renders the official, immutable View Estate logo asset.
///
/// The artwork is never redrawn, recoloured, cropped or rebuilt from text or symbols —
/// this view only ever loads the supplied files and preserves their original aspect ratio.
/// Variants exist purely as container behaviour, not as alternate artwork.
struct ViewEstateLogo: View {
    enum Variant {
        /// Official full-colour artwork (copper symbol, purple wordmark) — for light surfaces.
        case color
        /// Official light artwork supplied for dark surfaces.
        case light

        var assetName: String {
            switch self {
            case .color: "ViewEstateLogo"
            case .light: "ViewEstateLogoLight"
            }
        }
    }

    var variant: Variant = .light
    var width: CGFloat

    var body: some View {
        Image(variant.assetName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: width)
            .accessibilityLabel("View Estate")
    }
}

#Preview {
    ZStack {
        VE.canvas
        ViewEstateLogo(variant: .light, width: 240)
    }
    .ignoresSafeArea()
}
