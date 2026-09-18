import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

@main
struct MediaShuttleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    private var menuBarSymbol: String {
        model.canWipe ? "checkmark.shield.fill" : "externaldrive.badge.timemachine"
    }

    var body: some Scene {
        WindowGroup("Media Shuttle", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(model.appearance)
                .task { await model.start() }
        }
        .defaultSize(width: 1_120, height: 720)
        .defaultPosition(.center)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Media") {
                Button("Scan for Camera Media") { model.scanNow() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.isBusy)

                Button("Transfer and Verify") { model.startTransfer() }
                    .keyboardShortcut("t", modifiers: [.command])
                    .disabled(!model.canTransfer)

                Divider()

                Button("Open Destination") { model.openDestination() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!model.isDestinationAvailable)
            }
        }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(model.appearance)
        }

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label("Media Shuttle", systemImage: menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}
