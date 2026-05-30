import SwiftUI

struct AppLogo: View {
    var size: CGFloat

    var body: some View {
        Image("AppLogo")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder
    func logoGlassPlate(size: CGFloat, cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self
                .frame(width: size, height: size)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .frame(width: size, height: size)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                }
        }
        #else
        self
            .frame(width: size, height: size)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            }
        #endif
    }

    @ViewBuilder
    func adaptiveGlassSurface(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
        }
        #else
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            }
        #endif
    }
}
