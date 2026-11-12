import AppKit
import SwiftUI

/// Canon and Indy's visual language, taken from `Canon/canon/ui.py` and
/// `Indy/engine/aircover/ui.py` (Geist, one pink accent, pill buttons, 16px-radius cards,
/// the lowercase heavy wordmark with an accent bar), turned to dark: Canon's ink #111111
/// becomes the ground and the greys invert around it.
enum Theme {
    static let ground = Color(hex: 0x111111)   // window and panel background
    static let surface = Color(hex: 0x1A1A1A)  // cards, button fills
    static let zone = Color(hex: 0x232323)     // grouped areas, selected rows
    static let rail = Color(hex: 0x151515)     // side list, footer
    static let rule = Color(hex: 0x2C2C2C)
    static let outline = Color(hex: 0x555555)
    static let ink = Color(hex: 0xF2F2F2)      // primary text and outlines
    static let body = Color(hex: 0xC4C4C4)
    static let muted = Color(hex: 0x8F8F8F)
    static let inverse = Color(hex: 0x111111)  // text on an ink-filled pill
    static let onAccent = Color.white
    static let accent = Color(hex: 0xFF0055)
    static let dot = accent
    static let redText = accent                // the brand red itself, never a tint (4.7:1 on the ground)
    /// Quiet fills and hairlines for buttons, fields and pills.
    static let subtleFill = Color.white.opacity(0.06)
    static let subtleLine = Color.white.opacity(0.10)
    static let subtleOn = Color.white.opacity(0.14)
    static let groundNS = NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1)

    /// Geist when installed (it is on JJ's Mac), else the system font.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        NSFont(name: "Geist", size: size) != nil ? .custom("Geist", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    // Type scale from Canon's style sheet.
    static let h1 = font(28, .medium)          // Canon h1 is 40px; scaled for a window
    static let h2 = font(17, .semibold)
    // Light weights: regular Geist reads heavy as light text on a dark ground.
    static let text = font(14, .light)
    static let secondary = font(13, .light)
    static let meta = font(12)
    static let kind = font(12, .semibold)

    /// Dark only, so system controls (menus, checkboxes, fields) match the palette.
    static let appearance = NSAppearance(named: .darkAqua)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// A pill button with a faint fill and hairline, or the accent fill for the one primary action.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    var small = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? Theme.font(12) : Theme.font(13, .medium))
            .padding(.horizontal, small ? 12 : 16).padding(.vertical, small ? 4 : 7)
            .foregroundStyle(!enabled ? Theme.muted : primary ? Theme.onAccent : Theme.ink)
            .background(Capsule().fill(primary && enabled ? Theme.accent : enabled ? Theme.subtleFill : Color.clear))
            .overlay(Capsule().strokeBorder(primary && enabled ? Color.clear : Theme.subtleLine, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// A link-style button in Canon's body grey.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.secondary).foregroundStyle(Theme.body)
            .underline(configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Canon's status pill.
struct StatusPill: View {
    enum Style { case solid, outline, dashed, accent }
    let text: String
    var style: Style = .outline

    var body: some View {
        Text(text)
            .font(Theme.meta)
            .padding(.horizontal, 9).padding(.vertical, 1)
            .foregroundStyle(style == .solid ? Theme.ink : style == .accent ? Theme.onAccent : style == .dashed ? Theme.muted : Theme.body)
            .background(Capsule().fill(style == .solid ? Theme.subtleOn : style == .accent ? Theme.accent : Color.clear))
            .overlay(Capsule().strokeBorder(style == .dashed ? Theme.subtleOn : Theme.subtleLine,
                                            style: StrokeStyle(lineWidth: 1, dash: style == .dashed ? [3, 2] : []))
                        .opacity(style == .outline || style == .dashed ? 1 : 0))
    }
}

/// The lowercase heavy wordmark with the accent bar, as on Canon and Indy. Canon's CSS
/// (30px type, 36px line, bar `top:28.5px; height:4px; left:1.2px; right:2.6px` with 4px
/// right padding, drawn behind the letters) puts the bar's top edge on the baseline,
/// 0.133em deep, inset 0.04em at the start and running 0.047em past the last letter.
struct Wordmark: View {
    var text = "jotter"
    var size: CGFloat = 22

    var body: some View {
        Text(text)
            .font(Theme.font(size, .black))
            .tracking(-size * 0.05)
            .foregroundStyle(Theme.ink)
            .background(alignment: .topLeading) {
                Rectangle().fill(Theme.accent)
                    .frame(height: size * 0.133)
                    .padding(.leading, size * 0.04)
                    .padding(.trailing, -size * 0.047)
                    // Geist's ascent is 1.005em, so the baseline sits 1.005em below the top of
                    // the text; Canon's bar starts 0.005em above it.
                    .offset(y: size * 1.0)
            }
    }
}

/// Canon's card: white, hairline rule, 16px radius.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.rule))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

/// Canon's 8px notification dot.
struct Dot: View {
    var color = Theme.dot
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

/// A one-line caption reminding people of the key gestures. Plain text with the keys in
/// ink and the words in grey, so it never reads as a button. Follows the key chosen in the panel.
struct KeyHints: View {
    @AppStorage(HoldKey.defaultsKey) private var raw = HoldKey.rightCommand.rawValue
    private var key: HoldKey { HoldKey(rawValue: raw) ?? .rightCommand }

    var body: some View {
        (word("Hold ") + keys(key.symbol) + word(" to dictate, add ") + keys("⇧") + word(" to correct, double-tap to record"))
            .font(Theme.font(12, .light))
            .lineLimit(1)
            .fixedSize()
            .help("Change the key in the Jotter menu-bar panel.")
    }

    private func word(_ s: String) -> Text { Text(s).foregroundColor(Theme.muted) }
    private func keys(_ s: String) -> Text { Text(s).font(Theme.font(12, .medium)).foregroundColor(Theme.ink) }
}
