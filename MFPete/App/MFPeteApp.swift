//
//  MFPeteApp.swift
//  MFPete
//
//  Created by Pete McPherson on 10/1/26.
//

import SwiftData
import SwiftUI

@main
struct MFPeteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.appState)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.appState)
        }
        .menuBarExtraStyle(.menu)

        Window("Rules", id: WindowID.rules) {
            RulesWindow()
                .environment(appDelegate.appState)
        }
        .modelContainer(appDelegate.appState.modelContainer)

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}

enum WindowID {
    static let rules = "rules"
}
