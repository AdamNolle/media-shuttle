import AppKit
import Carbon
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when macOS started the app at login — Login Items, which `SMAppService.mainApp`
    /// registers — rather than someone opening it. `--background` forces the same path so it can
    /// be exercised without logging out.
    private var launchedInBackground: Bool {
        if ProcessInfo.processInfo.arguments.contains("--background") { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let background = launchedInBackground

        // Starting at login used to raise the window and take the foreground, in front of whatever
        // the reader had opened. A launch nobody asked for stays out of the way: no Dock icon, no
        // activation, no window — the menu bar extra is the whole of its presence until asked for
        // more. The window is ordered out rather than closed, so the card watcher its `task` owns
        // keeps running and an unattended transfer still happens.
        NSApp.setActivationPolicy(background ? .accessory : .regular)
        if !background {
            NSApp.activate(ignoringOtherApps: true)
        }

        // The packaged .app gets its Dock icon from Info.plist's CFBundleIconName, which
        // resolves through the Assets.car that scripts/package-macos.sh compiles from
        // Resources/MediaShuttle.icon. That key is inert for unbundled dev runs
        // (`swift run`), so render the same brand mark at launch to keep the Dock icon
        // consistent while developing.
        if !Bundle.isPackagedApp {
            NSApp.applicationIconImage = AppMark.renderedDockIcon()
        }

        if background {
            // The scene builds its window around this callback, so hide on the next turn of the
            // run loop, once there is something to hide.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.canBecomeMain {
                    window.orderOut(nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppDelegate.presentMainWindow()
        }
        return true
    }

    /// Brings the app forward from a background launch. The activation policy is raised first:
    /// an `.accessory` app can take the foreground but has no Dock icon and no place in the
    /// application switcher, which is wrong once it is showing a window.
    @MainActor
    static func presentMainWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
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
        .defaultSize(width: 1_060, height: 530)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
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
