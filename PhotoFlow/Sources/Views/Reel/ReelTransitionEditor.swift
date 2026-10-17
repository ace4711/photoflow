import SwiftUI

/// Övergångsinspektören (R2): visas när en övergång är markerad i tidslinjen. Typ, riktning (för
/// skjut), längd, låsstatus, "Använd på alla" och "Förhandsvisa". All logik som går att testa
/// ligger i `ReelEditorModel` och `ReelMotionPlanner`; vyn översätter bara val till modellanrop.
struct ReelTransitionEditor: View {
    let model: ReelEditorModel
    let preview: ReelPreviewModel
    let spec: ReelSpec
    /// Det inkommande klippets plats (> 0).
    let index: Int

    private enum Choice: Hashable { case auto, crossfade, cut, fadeThroughBlack, push }

    private var clip: ReelSpec.Clip { spec.timeline[index] }
    private var locked: Bool { clip.transitionLocked == true }
    /// Det som gäller för klippet (egen övergång, annars filmens standard), före klampning.
    private var configured: ReelSpec.Transition { clip.transitionIn ?? spec.style.defaultTransition }
    private var effective: ReelSpec.Transition? { ReelTimeline.transition(spec, at: index) }
    private var isCut: Bool { configured.type == .cut }

    private var choice: Choice {
        guard locked else { return .auto }
        switch configured.type {
        case .crossfade: return .crossfade
        case .cut: return .cut
        case .fadeThroughBlack: return .fadeThroughBlack
        case .push: return .push
        }
    }

    var body: some View {
        let rows = model.clipRows
        VStack(alignment: .leading, spacing: 12) {
            header(rows)

            Picker("Typ", selection: Binding(get: { choice }, set: { setChoice($0) })) {
                Text("Automatisk").tag(Choice.auto)
                Divider()
                Text("Mjuk tona (crossfade)").tag(Choice.crossfade)
                Text("Hårt klipp (cut)").tag(Choice.cut)
                Text("Via svart (fadeThroughBlack)").tag(Choice.fadeThroughBlack)
                Text("Skjut (push)").tag(Choice.push)
            }
            .pickerStyle(.menu)

            if configured.type == .push {
                Picker("Riktning", selection: Binding(get: { configured.direction ?? .left },
                                                      set: { setDirection($0) })) {
                    ForEach(Self.directions, id: \.0) { direction, arrow in
                        Text(arrow).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!locked)
                .help(locked ? "Åt vilket håll innehållet rör sig" : "Välj \"Skjut\" i menyn för att ändra riktning")
            }

            lengthRow

            lockStatus

            HStack(spacing: 12) {
                Button("Förhandsvisa", systemImage: "play.fill", action: previewTransition)
                    .help("Spelar från 1 s före övergången till 1 s efter")
                if locked {
                    Button("Använd på alla", systemImage: "rectangle.stack", action: { model.applyTransitionToAll(from: clip.asset) })
                        .help("Gör den här övergången till filmens standard och släpper alla låsta övergångar")
                }
            }
        }
    }

    // MARK: Delar

    private func header(_ rows: [ReelEditorModel.ClipRow]) -> some View {
        HStack(spacing: 8) {
            if rows.indices.contains(index) {
                thumbnail(rows[index - 1].url)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                thumbnail(rows[index].url)
            }
            Text("Övergång till klipp \(index + 1)").font(.headline)
        }
    }

    private func thumbnail(_ url: URL?) -> some View {
        LocalThumbnailView(url: url)
            .frame(width: 44, height: 33)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var lengthRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Längd").font(.callout)
                Slider(value: Binding(get: { configured.duration }, set: { setDuration($0) }),
                       in: ReelMotionPlanner.transitionRange, step: ReelTimelineLayout.transitionStep,
                       onEditingChanged: { editing in
                    if editing { model.beginCoalescing() } else { model.endCoalescing() }
                })
                .disabled(isCut)
                Text(isCut ? "–" : Self.seconds(configured.duration))
                    .font(.callout).monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            .opacity(isCut ? 0.5 : 1)
            if let shortened = Self.shortenedTo(configured: configured, effective: effective) {
                Label("Kortas till \(Self.seconds(shortened)) av klippets längd", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var lockStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if locked {
                HStack {
                    Label("Låst av dig", systemImage: "lock.fill").font(.caption).foregroundStyle(.orange)
                    Button("Tillbaka till automatisk") { model.clearTransition(clip.asset) }
                        .buttonStyle(.link).font(.caption)
                }
            } else {
                Text("Automatisk — vald av PhotoFlow").font(.caption).foregroundStyle(.secondary)
                Text(ReelMotionPlanner.transitionReason(previous: spec.timeline[index - 1],
                                                        isLast: index == spec.timeline.count - 1,
                                                        defaultTransition: spec.style.defaultTransition))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Åtgärder

    private func setChoice(_ choice: Choice) {
        // Längden följer nuvarande övergång (eller 0,5 s om den är ett hårt klipp utan längd).
        let duration = isCut ? max(spec.style.defaultTransition.duration, 0.5) : configured.duration
        switch choice {
        case .auto: model.clearTransition(clip.asset)
        case .crossfade: model.setTransition(clip.asset, .init(type: .crossfade, direction: nil, duration: duration))
        case .cut: model.setTransition(clip.asset, .init(type: .cut, direction: nil, duration: 0))
        case .fadeThroughBlack: model.setTransition(clip.asset, .init(type: .fadeThroughBlack, direction: nil, duration: duration))
        case .push: model.setTransition(clip.asset, .init(type: .push, direction: configured.direction ?? .left, duration: duration))
        }
    }

    private func setDirection(_ direction: ReelSpec.Direction) {
        var t = configured
        t.type = .push
        t.direction = direction
        model.setTransition(clip.asset, t)
    }

    private func setDuration(_ seconds: Double) {
        guard !isCut else { return }
        var t = configured
        t.duration = seconds
        model.setTransition(clip.asset, t)
    }

    private func previewTransition() {
        let starts = ReelTimeline.clipStarts(spec)
        let window = ReelPreviewModel.transitionWindow(start: starts[index], duration: effective?.duration ?? 0,
                                                       total: ReelTimeline.totalDuration(spec))
        preview.play(from: window.from, to: window.to)
    }

    // MARK: Text och hjälp

    static let directions: [(ReelSpec.Direction, String)] = [(.left, "←"), (.right, "→"), (.up, "↑"), (.down, "↓")]

    /// Sekunder med decimalkomma och två decimaler när steget är 0,05 ("0,45 s").
    static func seconds(_ s: Double) -> String {
        String(format: "%.2f s", s).replacingOccurrences(of: ".", with: ",")
    }

    /// Den effektiva längden om specens klampning gör den kortare än den inställda, annars nil.
    static func shortenedTo(configured: ReelSpec.Transition, effective: ReelSpec.Transition?) -> Double? {
        guard configured.type != .cut, configured.duration > 0 else { return nil }
        let e = effective?.duration ?? 0
        return e < configured.duration - 1e-9 ? e : nil
    }
}
