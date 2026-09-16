import Foundation
import UserNotifications
import AppKit

/// Fas 3e: systemnotiser (Notification Center) som komplement till ljud/tal
/// (`AudioService`) — talsyntesen hörs bara medan appen har fokus/ljud är på,
/// men en systemnotis syns även när huvudfönstret är stängt (menyradsläge)
/// eller datorn är på tyst. Behörighet begärs INTE vid appstart utan lat,
/// första gången en notis faktiskt ska skickas (`requestAuthorizationIfNeeded()`,
/// anropad från `send(...)`) — i praktiken alltid pipelinens "nya filer
/// hittade"-notis, dvs. första gången pipeline-läget faktiskt används. En
/// behörighetsdialog innan användaren ens sett appen göra något vore
/// förvirrande.
///
/// API:t är väletablerat (macOS 10.14+), så ingen ny SDK-verifiering av
/// signaturer behövdes utöver en snabb kontroll av delegatmetodernas exakta
/// Swift-namn (`UNUserNotificationCenter.h` i macOS 27-SDK:n) och att
/// `.banner`/`.list` (ersätter det numera deprecerade `.alert`) finns.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    // `nonisolated`: read from `UNUserNotificationCenterDelegate`'s
    // `nonisolated` callbacks (see below), which — under this project's
    // default `MainActor` actor isolation (Fas 2b) — would otherwise not be
    // able to touch a plain `static let` on this `@MainActor` class.
    private nonisolated static let categoryIdentifier = "PHOTOFLOW_PIPELINE"
    private nonisolated static let reviewActionIdentifier = "REVIEW_NOW"
    private nonisolated static let openFolderActionIdentifier = "OPEN_FOLDER"
    private nonisolated static let folderPathKey = "folderPath"

    private let settings = AppSettings.shared
    private var didRequestAuthorization = false

    /// Kopplas av `PhotoFlowApp` till att aktivera appen och öppna
    /// granskningsvyn.
    var onReviewNowRequested: (() -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let review = UNNotificationAction(
            identifier: Self.reviewActionIdentifier,
            title: "Granska nu",
            options: [.foreground]
        )
        let openFolder = UNNotificationAction(
            identifier: Self.openFolderActionIdentifier,
            title: "Öppna mapp",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [review, openFolder],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Begär notisbehörighet, men bara första gången per app-körning och bara
    /// när pipeline-läget faktiskt används (se klasskommentaren).
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        // Blocket måste vara nonisolated: UserNotifications svarar på en
        // bakgrundskö, och ett MainActor-isolerat block kraschar då direkt
        // i Swift 6:s isoleringskontroll innan kroppen körs.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
            if let error {
                print("[Notiser] Fel vid behörighetsbegäran: \(error.localizedDescription)")
            } else if !granted {
                print("[Notiser] Notisbehörighet nekad — systemnotiser visas inte (ljud/tal fungerar som vanligt).")
            }
        }
    }

    private func send(title: String, body: String, folderURL: URL? = nil, actionable: Bool = false) {
        guard settings.notificationsEnabled else { return }
        // Lat behörighetsbegäran: det första FAKTISKA notistillfället är i
        // praktiken alltid pipelinens "nya filer hittade"-notis, dvs. första
        // gången pipeline-läget används — se klasskommentaren.
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Ljud/tal hanteras redan separat av `AudioService` enligt användarens
        // befintliga ljudinställningar — ingen egen notisljud här, för att
        // undvika en dubbel signal för samma händelse.
        if actionable || folderURL != nil {
            content.categoryIdentifier = Self.categoryIdentifier
        }
        if let folderURL {
            content.userInfo = [Self.folderPathKey: folderURL.path]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Högnivåhändelser (se FORBATTRINGAR.md, Fas 3e)

    /// Nya filer hittades och pipelinen har startat automatiskt.
    func notifyPipelineStarting(fileCount: Int, folder: URL) {
        send(
            title: "PhotoFlow",
            body: "\(fileCount) nya bild(er) hittades — bearbetning startad.",
            folderURL: folder
        )
    }

    /// Pipelinen är klar och väntar på (valfri) granskning.
    func notifyReviewReady() {
        send(
            title: "Redo för granskning",
            body: "Bearbetningen är klar och väntar på din granskning.",
            actionable: true
        )
    }

    /// Ett fel uppstod i ett pipeline-steg.
    func notifyError(_ message: String) {
        send(title: "Fel i PhotoFlow", body: message)
    }

    /// HDR-sammanslagningen (hela steget, inte enskild ommerge) är klar.
    func notifyHDRComplete(successCount: Int, failCount: Int) {
        let body = failCount == 0
            ? "HDR-sammanslagning klar: \(successCount) grupper."
            : "HDR-sammanslagning klar: \(successCount) lyckades, \(failCount) misslyckades."
        send(title: "HDR klart", body: body)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Visar notisen som en banner även när appen redan är i förgrunden —
    /// utan detta skulle notiser bara synas medan appen är i bakgrunden/
    /// menyradsläge, vilket är precis tvärtom mot vad vi vill (notiserna ska
    /// synas OAVSETT om huvudfönstret är öppet).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let folderPath = response.notification.request.content.userInfo[Self.folderPathKey] as? String
        // Anropa `completionHandler()` direkt (inte inifrån `Task`) — systemet
        // väntar bara på en bekräftelse att svaret hanterades, inte på att
        // vårt MainActor-arbete (aktivera appen/öppna Finder) hunnit klart.
        // Att skicka en icke-Sendable completionHandler över aktörsgränsen
        // hade annars gett en data race-varning.
        Task { @MainActor in
            switch actionIdentifier {
            case Self.reviewActionIdentifier, UNNotificationDefaultActionIdentifier:
                NSApp.activate(ignoringOtherApps: true)
                NotificationService.shared.onReviewNowRequested?()
            case Self.openFolderActionIdentifier:
                if let folderPath {
                    NSWorkspace.shared.open(URL(fileURLWithPath: folderPath))
                }
            default:
                break
            }
        }
        completionHandler()
    }
}
