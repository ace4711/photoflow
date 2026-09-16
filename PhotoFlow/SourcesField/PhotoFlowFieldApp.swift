import SwiftUI

/// "PhotoFlow Fält" (Fas 7) — fristående iOS-app för att diktera
/// fältanteckningar per rum/bild ute på plats, med GPS-position och
/// tidsstämpel, som senare importeras och matchas mot bilderna i Mac-appen
/// (se `PipelineRunner+FieldNotes.swift` och `FieldNoteMatcher` i
/// `Sources/Shared`).
///
/// **Viktig begränsning** (se `FORBATTRINGAR.md`, Fas 7): det finns inget
/// riktigt signeringsteam för det här projektet, så appen byggs och körs
/// bara i Simulator — inga iCloud/CloudKit-entitlements används. Synk sker
/// uteslutande via en exporterad `.photoflownotes`-fil (delningsark/
/// Filer/AirDrop), som Mac-appen sedan importerar.
@main
struct PhotoFlowFieldApp: App {
    var body: some Scene {
        WindowGroup {
            FieldContentView()
        }
    }
}
