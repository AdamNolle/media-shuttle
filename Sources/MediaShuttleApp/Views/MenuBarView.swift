import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Media Shuttle") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Text(menuStatus)
        if let card = model.currentCard {
            Text("\(card.volumeLabel.prefix(24)) · \(model.media.count) files")
        }

        Divider()

        Button("Transfer and Verify") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.startTransfer()
        }
        .disabled(!model.canTransfer)

        Button("Open Destination", action: model.openDestination)
            .disabled(!model.isDestinationAvailable)

        SettingsLink { Text("Settings…") }

        Divider()

        Button("Quit Media Shuttle") {
            NSApp.terminate(nil)
        }
    }

    private var menuStatus: String {
        String(model.topStatus.prefix(30))
    }
}
