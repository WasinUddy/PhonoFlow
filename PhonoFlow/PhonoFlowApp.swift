//
//  PhonoFlowApp.swift
//  PhonoFlow
//
//  Created by Wasin Silakong on 26/3/2569 BE.
//

import SwiftUI

@main
struct PhonoFlowApp: App {
    @State private var audioManager = AudioDeviceManager()
    @State private var audioMonitor = AudioMonitor()
    @State private var appSettings = AppSettings()

    var body: some Scene {
        MenuBarExtra("PhonoFlow", image: "MenuBarIcon") {
            ContentView()
                .environment(audioManager)
                .environment(audioMonitor)
                .environment(appSettings)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

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

        let view = SettingsView()
            .environment(settings)

        let hostingController = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hostingController)
        win.title = "PhonoFlow Settings"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 480, height: 460))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate()
        self.window = win
    }
}
