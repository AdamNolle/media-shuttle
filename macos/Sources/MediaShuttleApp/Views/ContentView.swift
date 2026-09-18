import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showingEraseConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(model: model)
            Hairline()
            HStack(spacing: 0) {
                SourcePanel(model: model)
                    .frame(width: 216)
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                OperationsView(
                    model: model,
                    showEraseConfirmation: { showingEraseConfirmation = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.contentBackground)
        // Draw through the hidden title bar so the wordmark sits on the same
        // row as the traffic lights instead of in a band beneath them.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 940, minHeight: 470)
        .sheet(isPresented: $showingEraseConfirmation) {
            EraseConfirmationView(model: model) {
                showingEraseConfirmation = false
                model.wipeCard()
            } onCancel: {
                showingEraseConfirmation = false
            }
        }
    }
}

/// Replaces the stock toolbar. The window uses `.hiddenTitleBar`, so the
/// traffic lights float over this bar — hence the leading inset.
private struct TitleBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            AppMark(size: 15)

            Text("MEDIA SHUTTLE")
                .font(Theme.mono(10.5, .semibold))
                .tracking(1.15)
                .foregroundStyle(Theme.textPrimary)

            StatusPill(text: model.topStatus, tone: model.statusTone)

            Spacer(minLength: 12)

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(ChromeIconButtonStyle())
            .help("Settings")
        }
        .padding(.leading, 78)
        .padding(.trailing, 8)
        .frame(height: 38)
        .background(Theme.chromeBackground)
    }
}

private struct StatusPill: View {
    let text: String
    let tone: AppStatusTone

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(tone.color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(Theme.mono(9.5))
                .tracking(0.7)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.fill)
        .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Media status: \(text)")
    }
}
