import SwiftUI

/// On-screen sticky modifier keys, shown only when no hardware keyboard
/// is present. Tapping a modifier latches it down; tapping again releases.
/// The soft keyboard (invoked via the floating keyboard button) sends
/// subsequent character keystrokes that the host combines with the
/// latched modifiers — matching the iPadOS soft-keyboard behavior.
struct ModifierBar: View {
    @EnvironmentObject private var session: SessionModel
    let attentive: Bool
    let onInteraction: () -> Void

    init(attentive: Bool = true, onInteraction: @escaping () -> Void = {}) {
        self.attentive = attentive
        self.onInteraction = onInteraction
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SoftModifier.allCases, id: \.self) { modifier in
                Button(modifier.symbol) {
                    onInteraction()
                    session.toggleSoftModifier(modifier)
                }
                .buttonStyle(
                    ModifierButtonStyle(
                        active: session.isSoftModifierLatched(modifier),
                        attentive: attentive
                    )
                )
                .accessibilityValue(session.isSoftModifierLatched(modifier) ? "held" : "released")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
            Capsule()
                .fill(Color.black.opacity(attentive ? 0.14 : 0.04))
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(attentive ? 0.16 : 0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(attentive ? 0.28 : 0.1),
                radius: attentive ? 12 : 4,
                y: attentive ? 4 : 1)
        .animation(.easeInOut(duration: 0.3), value: attentive)
    }
}

private struct ModifierButtonStyle: ButtonStyle {
    let active: Bool
    let attentive: Bool

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = active || configuration.isPressed

        configuration.label
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .frame(minWidth: 44, minHeight: 38)
            .background(
                highlighted
                    ? AnyShapeStyle(Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1))
                    : AnyShapeStyle(Color.white.opacity(attentive ? 0.12 : 0.06)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.white.opacity(active ? 0.28 : (attentive ? 0.14 : 0.08)),
                        lineWidth: 1
                    )
            }
            .foregroundStyle(active ? Color.white : Color.primary.opacity(attentive ? 0.95 : 0.65))
            .scaleEffect(configuration.isPressed ? 0.94 : (active ? 1.04 : 1))
            .shadow(color: active ? Color.accentColor.opacity(0.35) : .clear,
                    radius: active ? 8 : 0,
                    y: active ? 2 : 0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.25), value: active)
            .animation(.easeInOut(duration: 0.3), value: attentive)
    }
}
