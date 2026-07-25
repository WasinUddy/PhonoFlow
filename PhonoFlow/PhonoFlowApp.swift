//
//  PhonoFlowApp.swift
//  PhonoFlow
//
//  Created by Wasin Silakong on 26/3/2569 BE.
//

import AppKit
import SwiftUI

@main
@MainActor
struct PhonoFlowApp: App {
    static let sharedCoordinator = AppCoordinator()
    #if DEBUG
        static let shouldPresentAcceptanceWindow =
            ProcessInfo.processInfo.environment[
                "PHONOFLOW_UI_TEST_WINDOW"
            ] == "1"
            || ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || UserDefaults.standard.bool(
                forKey: "phonoflowUITestWindow"
            )
    #endif

    @NSApplicationDelegateAdaptor(PhonoFlowApplicationDelegate.self)
    private var applicationDelegate
    @State private var coordinator: AppCoordinator

    init() {
        let coordinator = Self.sharedCoordinator
        _coordinator = State(initialValue: coordinator)
        #if DEBUG
            if Self.shouldPresentAcceptanceWindow {
                NSApplication.shared.setActivationPolicy(.regular)
            }
        #endif
        SettingsWindowController.shared.configure(coordinator: coordinator)
        coordinator.activate()
    }

    @SceneBuilder
    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(coordinator)
                .environment(coordinator.audioManager)
                .environment(coordinator.audioMonitor)
                .environment(coordinator.settings)
                .onAppear {
                    coordinator.activate()
                }
        } label: {
            Image("MenuBarIcon")
                .accessibilityLabel("PhonoFlow")
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
            Window("PhonoFlow Acceptance", id: "acceptance") {
                ContentView()
                    .environment(coordinator)
                    .environment(coordinator.audioManager)
                    .environment(coordinator.audioMonitor)
                    .environment(coordinator.settings)
                    .accessibilityIdentifier("PhonoFlow Acceptance")
            }
            .defaultSize(width: 560, height: 680)
            .defaultPosition(.center)
            .defaultLaunchBehavior(
                Self.shouldPresentAcceptanceWindow
                    ? .presented
                    : .suppressed
            )
        #endif
    }
}

@MainActor
final class PhonoFlowApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
            guard PhonoFlowApp.shouldPresentAcceptanceWindow else { return }

            NSApplication.shared.setActivationPolicy(.regular)
            Task { @MainActor in
                for _ in 0..<40 {
                    if let window = NSApplication.shared.windows.first(
                        where: { $0.title == "PhonoFlow Acceptance" }
                    ) {
                        // Let SwiftUI finish its initial scene sizing before
                        // enforcing the deterministic acceptance geometry.
                        try? await Task.sleep(for: .milliseconds(100))
                        window.identifier = NSUserInterfaceItemIdentifier(
                            "PhonoFlow Acceptance"
                        )
                        window.setAccessibilityIdentifier(
                            "PhonoFlow Acceptance"
                        )
                        window.setAccessibilityLabel("PhonoFlow Acceptance")
                        window.styleMask.remove(.resizable)
                        window.setContentSize(
                            NSSize(width: 560, height: 680)
                        )
                        window.center()
                        window.makeKeyAndOrderFront(nil)
                        window.orderFrontRegardless()
                        NSApplication.shared.activate()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        PhonoFlowApp.sharedCoordinator.shutdown()
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private weak var coordinator: AppCoordinator?

    func configure(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func open(settings: AppSettings) {
        if let existing = window {
            if !existing.isVisible {
                existing.center()
            }
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            NSApp.activate()
            return
        }

        let view: AnyView
        if let coordinator {
            view = AnyView(
                SettingsView()
                    .environment(settings)
                    .environment(coordinator)
                    .environment(coordinator.audioManager)
                    .environment(coordinator.audioMonitor)
            )
        } else {
            view = AnyView(SettingsView().environment(settings))
        }

        let hostingController = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hostingController)
        win.title = "PhonoFlow Settings"
        win.styleMask = [.titled, .closable, .resizable]
        win.contentMinSize = NSSize(width: 520, height: 440)
        win.setContentSize(NSSize(width: 620, height: 520))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate()
        self.window = win
    }
}
