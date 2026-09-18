import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showingEraseConfirmation = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            RadialGradient(
                colors: [Color.accentColor.opacity(0.08), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 620
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            ScrollView {
                HStack(alignment: .top, spacing: 22) {
                    SourcePanel(model: model)
                        .frame(width: 258)

                    OperationsView(
                        model: model,
                        showEraseConfirmation: { showingEraseConfirmation = true }
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: 1_220, alignment: .topLeading)
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
            }
        }
        .frame(minWidth: 960, minHeight: 650)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Label("Media Shuttle", systemImage: "arrow.triangle.2.circlepath.camera")
                    .font(.headline)
                    .symbolRenderingMode(.hierarchical)
            }
            ToolbarItem(placement: .principal) {
                StatusPill(text: model.topStatus, tone: model.statusTone)
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
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

private struct StatusPill: View {
    let text: String
    let tone: AppStatusTone

    private var color: Color {
        switch tone {
        case .neutral: .secondary
        case .active: .accentColor
        case .verified: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.7), radius: 4)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.5)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .glassCapsuleStyle()
        .overlay(Capsule().strokeBorder(color.opacity(0.24)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Media status: \(text)")
    }
}
