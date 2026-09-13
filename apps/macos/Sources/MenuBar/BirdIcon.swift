import SwiftUI

/// The approved full-bird identity. Images are compiled in Assets.xcassets;
/// template glyphs follow the system colour instead of painting a fixed tint.
public enum BirdIcon {
    public static let outlineName = "MynaOutline"
    public static let filledName = "MynaFilled"
    public static let artworkName = "MynaArtwork"

    public static var image: Image {
        Image(outlineName).renderingMode(.template)
    }

    public static var filledImage: Image {
        Image(filledName).renderingMode(.template)
    }

    public static var artwork: Image {
        Image(artworkName).renderingMode(.original)
    }
}

/// Outline when idle, filled while reading. Processing/pause/error retain
/// their existing system status symbols. No TimelineView or per-frame work.
public struct BirdIconView: View {
    public let state: IconState
    public let suppressAnimation: Bool

    public init(state: IconState, suppressAnimation: Bool = false) {
        self.state = state
        self.suppressAnimation = suppressAnimation
    }

    public var body: some View {
        Group {
            switch state {
            case .idle:
                BirdIcon.image.resizable().scaledToFit()
            case .speaking:
                BirdIcon.filledImage.resizable().scaledToFit()
            case .thinking:
                if #available(macOS 14.0, *), !suppressAnimation {
                    Image(systemName: "ellipsis.circle")
                        .symbolEffect(.pulse, options: .repeating)
                } else {
                    Image(systemName: "ellipsis.circle")
                }
            case .paused:
                Image(systemName: "pause.circle.fill")
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .frame(width: 20, height: 18)
        .accessibilityLabel("Myna \(state.rawValue)")
        .accessibilityValue(state.rawValue)
    }
}
