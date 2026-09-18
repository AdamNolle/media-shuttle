import SwiftUI

/// The app's brand mark — a red sync-arrow badge, matching `Resources/AppIcon.icns`.
/// Reused in-window (toolbar, dock icon rendered during unbundled dev runs) wherever
/// "Media Shuttle" identifies itself with its actual colors.
///
/// Note: `MenuBarExtra` forces its label to render as a monochrome template image at
/// the AppKit level — Shape fills and gradients never survive there, only an `Image`'s
/// alpha channel does — so the menu bar uses `AppMark.menuBarGlyph` instead of this view.
struct AppMark: View {
    var diameter: CGFloat = 18
    var showsConnectedDot = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.29, blue: 0.24), Color(red: 0.71, green: 0.10, blue: 0.09)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: diameter * 0.52, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .bottomTrailing) {
            if showsConnectedDot {
                Circle()
                    .fill(Color(red: 0.37, green: 0.82, blue: 0.54))
                    .frame(width: diameter * 0.34, height: diameter * 0.34)
                    .overlay(Circle().strokeBorder(.background, lineWidth: max(1, diameter * 0.07)))
                    .offset(x: diameter * 0.08, y: diameter * 0.08)
            }
        }
        .accessibilityHidden(true)
    }
}

extension AppMark {
    /// The same sync-arrow glyph, sized for `MenuBarExtra`. macOS templates this
    /// automatically (ignoring color), matching every other status-bar icon's look.
    static var menuBarGlyph: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 13, weight: .semibold))
    }

    /// Renders the mark to a bitmap so it can back `NSApp.applicationIconImage`
    /// when running unbundled (e.g. `swift run`), where Info.plist's `CFBundleIconFile`
    /// never takes effect. The packaged `.app` uses `Resources/AppIcon.icns` instead.
    @MainActor
    static func renderedDockIcon(size: CGFloat = 512) -> NSImage? {
        let renderer = ImageRenderer(
            content: AppMark(diameter: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .padding(size * 0.08)
        )
        renderer.scale = 2
        return renderer.nsImage
    }
}

#Preview {
    HStack(spacing: 16) {
        AppMark(diameter: 18)
        AppMark(diameter: 18, showsConnectedDot: true)
        AppMark(diameter: 64)
    }
    .padding()
}
