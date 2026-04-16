import SwiftUI

/// On-screen sticky modifier keys, shown only when no hardware keyboard
/// is present. Tapping a modifier latches it down; tapping again releases.
/// The soft keyboard (invoked via the floating keyboard button) sends
/// subsequent character keystrokes that the host combines with the
/// latched modifiers — matching the iPadOS soft-keyboard behavior.
struct ModifierBar: View {
    @EnvironmentObject private var session: SessionModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SoftModifier.allCases, id: \.self) { modifier in
                Button(modifier.symbol) { session.toggleSoftModifier(modifier) }
                    .buttonStyle(ModifierButtonStyle(active: session.isSoftModifierLatched(modifier)))
                    .accessibilityValue(session.isSoftModifierLatched(modifier) ? "held" : "released")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct ModifierButtonStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .frame(minWidth: 44, minHeight: 38)
            .background(
                active
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(active ? Color.white : Color.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
