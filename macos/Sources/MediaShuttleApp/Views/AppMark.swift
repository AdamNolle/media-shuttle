import AppKit
import SwiftUI

/// The app mark: the SD card drawn as a shuttle bus. Used in the window chrome, and as
/// the Dock icon for unbundled dev runs.
///
/// Drawn on the same grid as `docs/logo/media-shuttle-bus-small.svg` — 840 × 524, with
/// the card's chamfered corner at the top right and the driver's window repeating the
/// same cut — so this and the shipped icon are the same drawing at different fidelities.
///
/// The shipped icon is authored in Icon Composer (`Resources/MediaShuttle.icon`) and
/// compiled to `Resources/AppIcon.icns` by `scripts/build-icon.sh`.
struct AppMark: View {
    var size: CGFloat = 18

    var cardColor: Color = Theme.shuttleCard
    var glassColor: Color = Theme.shuttleGlass
    var tyreColor: Color = Theme.shuttleTyre
    var rimColor: Color = Theme.shuttleRim

    private static let design = CGSize(width: 840, height: 524)

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width / Self.design.width, canvasSize.height / Self.design.height)
            let dx = (canvasSize.width - Self.design.width * scale) / 2
            let dy = (canvasSize.height - Self.design.height * scale) / 2
            let transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)

            func draw(_ path: Path, _ color: Color, strokeWidth: CGFloat = 0) {
                let shape = path.applying(transform)
                context.fill(shape, with: .color(color))
                if strokeWidth > 0 {
                    context.stroke(
                        shape,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: strokeWidth * scale, lineCap: .round, lineJoin: .round)
                    )
                }
            }

            // The card, its corners rounded by a stroke of its own colour so the two
            // ends of the chamfer round exactly as much as the square corners do.
            var card = Path()
            card.move(to: CGPoint(x: 20, y: 20))
            card.addLine(to: CGPoint(x: 690, y: 20))
            card.addLine(to: CGPoint(x: 820, y: 150))
            card.addLine(to: CGPoint(x: 820, y: 434))
            card.addLine(to: CGPoint(x: 20, y: 434))
            card.closeSubpath()
            draw(card, cardColor, strokeWidth: 40)

            draw(
                Path(roundedRect: CGRect(x: 46, y: 46, width: 512, height: 362), cornerRadius: 54),
                Theme.shuttleYellow
            )

            for x in [CGFloat(80), 237, 394] {
                draw(
                    Path(roundedRect: CGRect(x: x, y: 80, width: 130, height: 128), cornerRadius: 14),
                    glassColor
                )
            }

            var driver = Path()
            driver.move(to: CGPoint(x: 602, y: 80))
            driver.addLine(to: CGPoint(x: 692, y: 80))
            driver.addLine(to: CGPoint(x: 748, y: 136))
            driver.addLine(to: CGPoint(x: 748, y: 208))
            driver.addLine(to: CGPoint(x: 602, y: 208))
            driver.closeSubpath()
            draw(driver, glassColor, strokeWidth: 22)

            draw(
                Path(roundedRect: CGRect(x: 80, y: 278, width: 444, height: 20), cornerRadius: 10),
                glassColor
            )

            for x in [CGFloat(188), 686] {
                draw(Path(ellipseIn: CGRect(x: x - 84, y: 356, width: 168, height: 168)), tyreColor)
                draw(Path(ellipseIn: CGRect(x: x - 42, y: 398, width: 84, height: 84)), rimColor)
            }
        }
        .frame(width: size, height: size * (Self.design.height / Self.design.width))
        .accessibilityHidden(true)
    }
}

extension AppMark {
    /// The menu bar label. macOS renders `MenuBarExtra` labels as monochrome template
    /// images, so this is a plain symbol rather than the tinted mark above — which is
    /// also what every other status item looks like.
    static var menuBarGlyph: some View {
        Image(systemName: "bus.fill")
            .font(.system(size: 13.5, weight: .regular))
    }

    /// Backs `NSApp.applicationIconImage` when running unbundled (`swift run`), where
    /// Info.plist's `CFBundleIconFile` has no effect. The packaged .app uses
    /// `Resources/AppIcon.icns`. This is the icon tile rather than the bare mark: on
    /// its own tile the bus keeps the logo's own black card instead of borrowing the
    /// chrome's foreground colour.
    @MainActor
    static func renderedDockIcon(size: CGFloat = 512) -> NSImage? {
        let tile = ZStack {
            RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.925, green: 0.361, blue: 0.302),
                            Color(red: 0.824, green: 0.216, blue: 0.184),
                            Color(red: 0.533, green: 0.125, blue: 0.102)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            AppMark(
                size: size * 0.82,
                cardColor: Color(red: 0.078, green: 0.086, blue: 0.106),
                glassColor: Color(red: 0.071, green: 0.082, blue: 0.110),
                tyreColor: Color(red: 0.055, green: 0.063, blue: 0.082)
            )
        }
        .frame(width: size, height: size)

        let renderer = ImageRenderer(content: tile)
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
    .background(Theme.chromeBackground)
}
