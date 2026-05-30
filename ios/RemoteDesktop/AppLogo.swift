import SwiftUI

struct AppLogo: View {
    var size: CGFloat

    var body: some View {
        Image(systemName: "display")
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.62, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder
    func logoGlassPlate(size: CGFloat, cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
                .frame(width: size, height: size)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .frame(width: size, height: size)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 8)
        }
        #else
        self
            .frame(width: size, height: size)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 8)
        #endif
    }

    @ViewBuilder
    func adaptiveGlassSurface(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                }
        }
        #else
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            }
        #endif
    }
}
