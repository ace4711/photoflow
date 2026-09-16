import AVFoundation

/// Fas 8: `@unchecked Sendable`-wrapper runt en `AVAudioPCMBuffer` som just
/// skapats som en helt egen, oaliaserad kopia (se `DictationService`s och
/// `FieldDictationService`s `copyPCMBuffer`-hjälpare) — `AVAudioPCMBuffer`
/// själv är inte `Sendable` i Apples SDK, och Swifts regionbaserade
/// isoleringskontroll kan inte bevisa att en buffert byggd via råpekare
/// (`UnsafeMutableAudioBufferListPointer`) är fri från alias, trots att den
/// faktiskt är det. Samma escape-hatch-mönster som `ProcessCancellationBox`
/// (`Services/Pipeline/ProcessRunner.swift`) — en pragmatisk, medveten
/// `@unchecked Sendable` för ett fall vi själva kan verifiera är säkert,
/// inte ett sätt att tysta ett verkligt datarace.
nonisolated struct SendableAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
