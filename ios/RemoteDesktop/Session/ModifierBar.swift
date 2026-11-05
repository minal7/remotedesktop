import SwiftUI

/// Shared surface for controls floating over the remote screen.
struct SessionGlass<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                // The tint keeps controls readable over bright or busy remote screens.
                content.glassEffect(.regular.tint(.black.opacity(0.4)), in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay { shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

extension View {
    func sessionGlass<S: InsettableShape>(in shape: S) -> some View {
        modifier(SessionGlass(shape: shape))
    }
}

/// On-screen sticky modifier keys, shown only when no hardware keyboard
/// is present. Tapping a modifier latches it down; tapping again releases.
/// The soft keyboard sends subsequent character keystrokes that the host
/// combines with the latched modifiers.
struct ModifierKeys: View {
    @EnvironmentObject private var session: SessionModel
    var onInteraction: () -> Void = {}

    var body: some View {
        let generation = session.remoteInputGeneration
        return HStack(spacing: 2) {
            ForEach(SoftModifier.allCases, id: \.self) { modifier in
                Button(modifier.symbol) {
                    onInteraction()
                    session.toggleSoftModifier(modifier, expectedInputGeneration: generation)
                }
                .buttonStyle(SessionKeyStyle(active: session.isSoftModifierLatched(modifier)))
                .accessibilityValue(session.isSoftModifierLatched(modifier) ? "held" : "released")
            }
        }
        .id(generation)
    }
}

/// The modifier keys on their own surface, for layouts without the session dock.
struct ModifierBar: View {
    var body: some View {
        ModifierKeys()
            .padding(4)
            .sessionGlass(in: Capsule())
    }
}

/// One key of the session dock: quiet until pressed or latched.
struct SessionKeyStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .medium))
            .frame(width: 44, height: 44)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background {
                if active {
                    Circle().fill(Color.accentColor)
                } else if configuration.isPressed {
                    Circle().fill(Color.white.opacity(0.18))
                }
            }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.2), value: active)
    }
}
