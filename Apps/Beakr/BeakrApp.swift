//
//  BeakrApp.swift
//  Beakr
//
//  Created by Ice-9 on 2026-10-03.
//

import SwiftUI

@main
@MainActor
struct BeakrApp: App {
    @State private var applicationModel = BeakrApplicationModel()

    var body: some Scene {
#if os(macOS)
        Window("Beakr", id: "main") {
            ContentView(
                model: applicationModel.messageComposer,
                bootstrap: applicationModel.bootstrap
            )
            .task { await applicationModel.start() }
        }
        .defaultSize(width: 1_200, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            BeakrMainWindowCommands()
        }

        Settings {
            BeakrSettingsView(bootstrap: applicationModel.bootstrap)
        }
        .defaultSize(width: 820, height: 600)
        .windowToolbarStyle(.unified)
#else
        WindowGroup {
            ContentView(
                model: applicationModel.messageComposer,
                bootstrap: applicationModel.bootstrap
            )
        }
#endif
    }
}

@MainActor
@Observable
private final class BeakrApplicationModel {
    let messageComposer: MessageComposerModel
    let bootstrap: NodeBootstrapModel

    init() {
        let inbox = ApplicationMessageInbox()
        let deliveryUpdates = ApplicationDeliveryUpdates()
        messageComposer = MessageComposerModel(
            messagingService: UnconfiguredHostMessagingService(),
            inbox: inbox,
            deliveryUpdates: deliveryUpdates
        )
        let composer = messageComposer
        let lanRuntime = ApplicationLANRuntimeManager(
            inbox: inbox,
            deliveryUpdates: deliveryUpdates,
            mailboxMetadataAttachment: { url in
                composer.attachMailboxMetadata(fileURL: url)
            }
        )
        messageComposer.replaceMessagingService(lanRuntime)
        bootstrap = NodeBootstrapModel(lanRuntimeManager: lanRuntime)
    }

    func start() async {
        await bootstrap.start()
    }
}

#if os(macOS)
private struct BeakrMainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Show Beakr") {
                openWindow(id: "main")
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
#endif
