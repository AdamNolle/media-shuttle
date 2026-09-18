import AppKit
import SwiftUI

/// A miniature of the app icon — a white SD card on the red tile — used in the
/// window chrome, and as the Dock icon for unbundled dev runs.
///
/// The shipped icon is authored in Icon Composer (`Resources/MediaShuttle.icon`)
/// and compiled to `Resources/AppIcon.icns` by `scripts/build-icon.sh`.
struct AppMark: View {
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.902, green: 0.254, blue: 0.207),
                        Color(red: 0.352, green: 0.035, blue: 0.031)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

extension AppMark {
    /// The menu bar label. macOS renders `MenuBarExtra` labels as monochrome
    /// template images, so this is the plain SD card symbol rather than the
    /// tinted mark above — which is also what every other status item looks like.
    static var menuBarGlyph: some View {
        Image(systemName: "sdcard.fill")
            .font(.system(size: 13.5, weight: .regular))
    }

    /// Backs `NSApp.applicationIconImage` when running unbundled (`swift run`),
    /// where Info.plist's `CFBundleIconFile` has no effect. The packaged .app
    /// uses `Resources/AppIcon.icns`.
    @MainActor
    static func renderedDockIcon(size: CGFloat = 512) -> NSImage? {
        let renderer = ImageRenderer(content: AppMark(size: size).padding(size * 0.06))
        renderer.scale = 2
        return renderer.nsImage
    }
}

#Preview {
    HStack(spacing: 16) {
        AppMark(size: 16)
        AppMark(size: 32)
        AppMark(size: 96)
        AppMark.menuBarGlyph
    }
    .padding()
}
