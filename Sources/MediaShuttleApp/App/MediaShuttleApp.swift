import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // The packaged .app gets its Dock icon from Info.plist's CFBundleIconFile
        // (Resources/AppIcon.icns, applied by scripts/package-macos.sh). That key is
        // inert for unbundled dev runs (`swift run`), so render the same brand mark
        // at launch to keep the Dock icon consistent while developing.
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.applicationIconImage = AppMark.renderedDockIcon()
        }
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
            AppMark.menuBarGlyph
        }
        .menuBarExtraStyle(.menu)
    }
}
