//
//  DoubaoVoiceApp.swift
//  DoubaoVoice
//
//  Menu bar app entry point
//

import SwiftUI

@main
struct DoubaoVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
