import MediaShuttleCore
import SwiftUI

struct OperationsView: View {
    @Bindable var model: AppModel
    let showEraseConfirmation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let banner = model.banner {
                BannerView(message: banner, onDismiss: model.dismissBanner)
            }

            hero
            SessionPanel(model: model)

            if model.settings.showActivityLog {
                activity
            }

            erasePanel
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                SectionLabel("VERIFIED CAMERA INGEST")
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if let card = model.currentCard {
                    Label(card.volumeLabel, systemImage: "externaldrive.fill")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: model.canWipe
                                    ? [Color.green, Color.teal]
                                    : [Color.accentColor, Color.indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: model.canWipe ? "checkmark.shield.fill" : "camera.aperture")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 66, height: 66)
                .shadow(
                    color: (model.canWipe ? Color.green : Color.accentColor).opacity(0.22),
                    radius: 12,
                    y: 6
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    Text(model.heroTitle)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .tracking(-0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.heroSubtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    Button(model.primaryActionTitle) { model.startTransfer() }
                        .primaryActionStyle()
                        .controlSize(.large)
                        .frame(width: 178)
                        .disabled(!model.canTransfer)
                    if model.isBusy && model.progress.phase != .erasing && model.progress.phase != .reVerifying {
                        Button("Cancel transfer") { model.cancelTransfer() }
                            .frame(width: 178)
                    }
                }
            }
        }
        .padding(22)
        .panelStyle()
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("ACTIVITY")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(model.activities.prefix(12)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 74)
        }
    }

    private var erasePanel: some View {
        HStack(spacing: 16) {
            Image(systemName: model.canWipe ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(model.canWipe ? .red : .secondary)
                .frame(width: 42, height: 42)
                .background(
                    model.canWipe ? Color.red.opacity(0.10) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    SectionLabel("ERASE CARD CONTENTS")
                        .foregroundStyle(.red)
                    Text(model.canWipe ? "UNLOCKED" : "LOCKED")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(model.canWipe ? .red : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            model.canWipe ? Color.red.opacity(0.09) : Color.secondary.opacity(0.08),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(model.canWipe ? Color.red.opacity(0.65) : Color.secondary.opacity(0.3))
                        )
                }
                Text(eraseDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Erase card…", role: .destructive, action: showEraseConfirmation)
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
                .disabled(!model.canWipe)
        }
        .padding(18)
        .destructivePanelStyle(enabled: model.canWipe)
    }

    private var eraseDescription: String {
        if model.canWipe {
            return "Unlocked — every remaining media file has a verified destination copy."
        }
        if model.media.isEmpty, model.currentCard != nil {
            return "No verified media is available to erase."
        }
        return "Locked until every remaining camera file has a verified destination copy."
    }
}

private struct SessionPanel: View {
    @Bindable var model: AppModel

    private var progressColor: Color {
        switch model.progress.phase {
        case .complete:
            .green
        case .error:
            .red
        case .cancelled:
            .orange
        default:
            .accentColor
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    SectionLabel("THIS SESSION")
                    Spacer()
                    Text(model.progress.phase.label)
                        .foregroundStyle(progressColor)
                    Text(model.progress.fraction, format: .percent.precision(.fractionLength(0)))
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))

                ProgressView(value: model.progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(progressColor)

                HStack(spacing: 12) {
                    Metric(label: "COPIED", value: "\(model.progress.copiedFiles.formatted()) files")
                    Metric(label: "ALREADY SAFE", value: "\(model.progress.skippedFiles.formatted()) files")
                    Metric(label: "PROCESSED", value: processedText)
                    Metric(
                        label: "THROUGHPUT",
                        value: model.throughputBytesPerSecond.map {
                            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + "/s"
                        } ?? "—"
                    )
                    Metric(label: "ELAPSED", value: elapsedString(model.elapsed))
                }

                Divider()

                HStack(spacing: 12) {
                    Text(currentActivity)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Report", action: model.openReport)
                        .disabled(model.reportURL == nil)
                    Button("Transfer again", action: model.startTransfer)
                        .disabled(!model.canTransfer || model.verifiedSession == nil)
                }
            }
            .padding(20)
            .panelStyle()
        }
    }

    private var processedText: String {
        guard model.progress.processedBytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(
            fromByteCount: model.progress.processedBytes,
            countStyle: .file
        )
    }

    private var currentActivity: String {
        guard let source = model.progress.currentSourceURL else { return model.progress.currentItem }
        let folder = model.progress.currentDestinationFolder
        return folder.isEmpty
            ? source.path
            : "LAST · \(source.path) → \(folder)"
    }

    private func elapsedString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct Metric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(label)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BannerView: View {
    let message: BannerMessage
    let onDismiss: () -> Void

    private var color: Color {
        switch message.tone {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: message.tone == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title).fontWeight(.semibold)
                Text(message.message).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.35)))
    }
}
