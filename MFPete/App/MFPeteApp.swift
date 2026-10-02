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

        Window("Activity", id: WindowID.activity) {
            ActivityWindow()
                .environment(appDelegate.appState)
        }
        .defaultSize(width: 860, height: 480)

        Window("Welcome to MFPete", id: WindowID.onboarding) {
            OnboardingWindow()
                .environment(appDelegate.appState)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}

enum WindowID {
    static let rules = "rules"
    static let activity = "activity"
    static let onboarding = "onboarding"
}
