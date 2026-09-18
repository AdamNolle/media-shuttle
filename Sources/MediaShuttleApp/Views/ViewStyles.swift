import SwiftUI

struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.15)
            .foregroundStyle(.secondary)
    }
}

private struct PanelStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark
                                ? Color.white.opacity(0.10)
                                : Color.white.opacity(0.8),
                            lineWidth: 1
                        )
                }
        }
    }
}

private struct DestructivePanelStyle: ViewModifier {
    let enabled: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(enabled ? Color.red.opacity(0.12) : Color.secondary.opacity(0.035)),
                    in: .rect(cornerRadius: 16)
                )
        } else {
            content
                .background(
                    enabled ? Color.red.opacity(0.05) : Color.secondary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(enabled ? Color.red.opacity(0.3) : Color.secondary.opacity(0.12))
                }
        }
    }
}

private struct GlassCapsuleStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.thinMaterial, in: Capsule())
        }
    }
}
private struct SecondaryActionStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}


private struct PrimaryActionStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    func panelStyle() -> some View {
        modifier(PanelStyle())
    }

    func destructivePanelStyle(enabled: Bool) -> some View {
        modifier(DestructivePanelStyle(enabled: enabled))
    }

    func glassCapsuleStyle() -> some View {
        modifier(GlassCapsuleStyle())
    }

    func secondaryActionStyle() -> some View {
        modifier(SecondaryActionStyle())
    }

    func primaryActionStyle() -> some View {
        modifier(PrimaryActionStyle())
    }
}
