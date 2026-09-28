import Foundation

/// Output pixel size requested from the model. The server snaps it to what the chosen model
/// supports; the client only needs the ratio to be right.
enum OutputSize {
    static let longEdge = 1536

    static func pixels(for ratio: AspectRatio) -> (width: Int, height: Int) {
        let long = Double(longEdge)
        if ratio.width == ratio.height { return (longEdge, longEdge) }
        let shortRaw = ratio.isLandscape ? long * ratio.height / ratio.width : long * ratio.width / ratio.height
        let short = max(512, Int((shortRaw / 64).rounded()) * 64)
        return ratio.isLandscape ? (longEdge, short) : (short, longEdge)
    }
}
