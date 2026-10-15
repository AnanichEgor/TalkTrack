import AppKit
import SwiftUI
import TalkTrackDomain

extension Color {
    /// System colors for text. In light appearance they are darkened so text
    /// keeps at least 4.5:1 contrast on window backgrounds; dark is unchanged.
    static func readable(_ color: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color : color.blended(withFraction: 0.35, of: .black) ?? color
        })
    }

    /// A speaker's name color: `You` teal, system voices by their position in
    /// the meeting's speaker list, so Transcript and Translation agree. The
    /// text label always carries identity.
    static func speaker(_ speaker: SpeakerReference, order: [UUID]) -> Color {
        guard case .system(let id) = speaker else { return readable(.systemTeal) }
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemPink, .systemIndigo, .systemBrown, .systemGreen, .systemCyan]
        let index = order.firstIndex(of: id) ?? 0
        return readable(palette[index % palette.count])
    }

    static let errorText = readable(.systemRed)
    static let pausedText = readable(.systemOrange)
}
