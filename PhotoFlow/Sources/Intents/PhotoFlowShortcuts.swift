import AppIntents

/// Fas 3f: gor PhotoFlows intents sokbara i Genvagar/Spotlight/Siri UTAN att
/// anvandaren behover skapa nagon genvag sjalv — `AppShortcutsProvider`
/// registrerar dem automatiskt vid appstart. `\(.applicationName)` ersatts
/// av systemet med appens visningsnamn ("PhotoFlow").
struct PhotoFlowShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartPipelineIntent(),
            phrases: [
                "Bearbeta bilder med \(.applicationName)",
                "Starta \(.applicationName)",
                "Kor \(.applicationName)-pipelinen"
            ],
            shortTitle: "Bearbeta bilder",
            systemImageName: "photo.stack"
        )
        AppShortcut(
            intent: ToggleWatchIntent(),
            phrases: [
                "Starta \(.applicationName)-bevakning",
                "Stoppa \(.applicationName)-bevakning",
                "Vaxla bevakning i \(.applicationName)"
            ],
            shortTitle: "Bevakning",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: SessionStatusIntent(),
            phrases: [
                "Status for \(.applicationName)",
                "Vad gor \(.applicationName)"
            ],
            shortTitle: "Status",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: ShowReviewIntent(),
            phrases: [
                "Granska bilder i \(.applicationName)",
                "Oppna granskning i \(.applicationName)"
            ],
            shortTitle: "Granska",
            systemImageName: "hand.tap"
        )
        AppShortcut(
            intent: FindSessionsIntent(),
            phrases: [
                "Hitta sessioner i \(.applicationName)",
                "Visa adresser i \(.applicationName)"
            ],
            shortTitle: "Sessioner",
            systemImageName: "mappin.and.ellipse"
        )
    }
}
