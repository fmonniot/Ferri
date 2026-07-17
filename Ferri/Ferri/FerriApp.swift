//
//  FerriApp.swift
//  Ferri
//
//  Created by François Monniot on 3/14/26.
//

import SwiftUI
import FTPClient

@main
struct FerriApp: App {
    init() {
        FerriLogging.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection") {
                    NotificationCenter.default.post(name: .newConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)),
                        with: nil
                    )
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            
            CommandGroup(replacing: .toolbar) {
                Button("Refresh") {
                    NotificationCenter.default.post(name: .refresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandMenu("Go") {
                Button("Back") {
                    NotificationCenter.default.post(name: .navigateBack, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    NotificationCenter.default.post(name: .navigateForward, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Enclosing Folder") {
                    NotificationCenter.default.post(name: .navigateUp, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let newConnection = Notification.Name("newConnection")
    static let refresh = Notification.Name("refresh")
    static let navigateBack = Notification.Name("navigateBack")
    static let navigateForward = Notification.Name("navigateForward")
    static let navigateUp = Notification.Name("navigateUp")
}
