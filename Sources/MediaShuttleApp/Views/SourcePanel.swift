import MediaShuttleCore
import SwiftUI

struct SourcePanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("SOURCE")
            sourceSummary
                .padding(.top, 14)

            Divider()
                .padding(.vertical, 24)

            SectionLabel("CARD CONTENTS")
            MediaBreakdown(counts: model.mediaCounts)
                .padding(.top, 12)

            Divider()
                .padding(.vertical, 24)

            SectionLabel("DESTINATION")
            destination
                .padding(.top, 12)
        }
        .padding(18)
        .panelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source media summary")
    }

    private var assetCount: Int {
        model.mediaCounts.values.reduce(0, +)
    }

    private var destinationDisplayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = model.destinationURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var sourceSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            MediaCardIcon(connected: model.currentCard != nil)
                .frame(width: 34, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.currentCard?.volumeLabel ?? "No card connected")
                    .font(.headline)
                    .lineLimit(1)
                if let card = model.currentCard {
                    Text("\(card.rootURL.path) · \(card.driveType)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(
                        "\(assetCount.formatted()) assets · " +
                        ByteCountFormatter.string(fromByteCount: model.totalMediaBytes, countStyle: .file)
                    )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                } else {
                    Text("Insert a camera card or connect camera storage to begin.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("—")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(destinationDisplayPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Destination folder")

            HStack(spacing: 8) {
                Button(action: model.chooseDestination) {
                    Label("Choose", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .secondaryActionStyle()
                Button(action: model.openDestination) {
                    Label("Open", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .secondaryActionStyle()
                .disabled(!model.isDestinationAvailable)
            }
            .controlSize(.large)

            Text("Photos/JPEGs\nPhotos/RAWs\nPhotos/Other\nVideos")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineSpacing(4)
        }
    }
}

private struct MediaCardIcon: View {
    let connected: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 4,
                topTrailingRadius: 11
            )
            .fill(
                LinearGradient(
                    colors: [.primary.opacity(0.16), .primary.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .stroke(.separator)
            Capsule()
                .fill(connected ? Color.accentColor : Color.secondary)
                .frame(width: 3, height: 25)
                .padding(.leading, 6)
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { _ in
                    Rectangle().fill(.secondary).frame(width: 2, height: 6)
                }
            }
            .offset(x: 14, y: 13)
        }
        .accessibilityHidden(true)
    }
}

private struct MediaBreakdown: View {
    let counts: [MediaKind: Int]

    private var itemCount: Int {
        counts.values.reduce(0, +)
    }

    private var total: Double {
        Double(max(1, itemCount))
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        let width = proxy.size.width * Double(counts[kind, default: 0]) / total
                        if width > 0 {
                            Capsule()
                                .fill(kind.color)
                                .frame(width: width)
                        }
                    }
                    if itemCount == 0 {
                        Capsule().fill(.quaternary)
                    }
                }
            }
            .frame(height: 7)

            VStack(spacing: 8) {
                ForEach(MediaKind.allCases, id: \.self) { kind in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(kind.color)
                            .frame(width: 7, height: 7)
                        Text(kind.label)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(counts[kind, default: 0].formatted())
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
    }
}

extension MediaKind {
    fileprivate var color: Color {
        switch self {
        case .jpeg: Color(red: 0.25, green: 0.27, blue: 0.31)
        case .raw: Color(red: 0.42, green: 0.44, blue: 0.48)
        case .otherPhoto: Color(red: 0.60, green: 0.62, blue: 0.65)
        case .video: Color(red: 0.76, green: 0.78, blue: 0.81)
        }
    }
}
