import SwiftUI
import AppKit

/// Filmlistan för en session: alla renderade filmer i sessionens FILM-mappar, med miniatyr, format,
/// längd, serverstatus och knapparna Spela, Visa i Finder, Dela och Öppna i Bildspel. Öppnas som eget
/// fönster (`ReelFilmsWindow.id`) från Historiken ("Filmer") och dashboardens Bildspel-meny.
/// Logiken ligger i `ReelFilmListModel`; vyn ritar bara.
struct ReelFilmListView: View {
    let outputDirectory: URL

    @State private var model = ReelFilmListModel()
    @Environment(\.openWindow) private var openWindow

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "sv_SE")
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isEmpty {
                emptyState
            } else if !model.hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.folders) { folder in
                        Section { rows(for: folder) } header: { sectionHeader(folder) }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .navigationTitle("Filmer")
        .task(id: outputDirectory) { await model.load(outputDirectory: outputDirectory) }
    }

    // MARK: Huvud

    private var header: some View {
        HStack {
            Label("Filmer i sessionen", systemImage: "film.stack").font(.headline)
            Text(outputDirectory.path)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            Button("Uppdatera", systemImage: "arrow.clockwise") {
                Task { await model.load(outputDirectory: outputDirectory, force: true) }
            }
            .disabled(model.isLoading)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Inga filmer än", systemImage: "film")
        } description: {
            Text("Pipelinen skapar ett filmförslag per adress (steget Filmförslag). Du kan också göra en film själv: öppna Bildspel för adressen och tryck Rendera. Den färdiga MP4:n hamnar i mappen \"<adress> FILM\" och visas här.")
        } actions: {
            Button("Nytt bildspel…") { openWindow(id: ReelWindow.id, value: newReelRequest) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var newReelRequest: ReelLaunchRequest {
        ReelLaunchRequest(startPath: outputDirectory.path, outputPath: outputDirectory.path)
    }

    // MARK: Per FILM-mapp

    private func sectionHeader(_ folder: ReelFilmFolder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(folder.address).font(.headline)
                if let badge = model.badge(for: folder) {
                    Text(badge.label)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(badgeColor(badge).opacity(0.2), in: Capsule())
                }
                Spacer()
                Button("Öppna i Bildspel", systemImage: "slider.horizontal.3") {
                    openWindow(id: ReelWindow.id, value: ReelLaunchRequest.forFilmFolder(folder, outputDirectory: outputDirectory))
                }
                if folder.remote != nil {
                    Button("Ny länk…", systemImage: "link.badge.plus") {
                        openWindow(id: ReelWindow.id, value: ReelLaunchRequest.forFilmFolder(
                            folder, outputDirectory: outputDirectory, showShare: true))
                    }
                    .disabled(folder.sourceDirectory() == nil)
                    .help("Öppnar Bildspel och delningsarket för att skapa en ny mäklarlänk (länkens hemliga del sparas aldrig, så en gammal länk går inte att kopiera)")
                }
            }
            .controlSize(.small)
            Text(folderDetails(folder)).font(.caption).foregroundStyle(.secondary)
            if let note = model.statusNote(for: folder) {
                Label(note, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
            }
            ForEach(model.links(for: folder)) { link in
                Label(link.summary(), systemImage: link.revokedAt != nil || link.isExpired(now: Date()) ? "link.badge.plus" : "link")
                    .font(.caption)
                    .foregroundStyle(link.revokedAt != nil || link.isExpired(now: Date()) ? .secondary : .primary)
            }
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }

    private func folderDetails(_ folder: ReelFilmFolder) -> String {
        var parts: [String] = []
        if let clips = folder.clipCount { parts.append("\(clips) klipp") }
        if let revision = folder.revision { parts.append("revision \(revision)") }
        if let duration = folder.specDuration { parts.append(ReelLibrary.durationText(duration)) }
        if folder.films.isEmpty { parts.append("ingen renderad film än") }
        return parts.joined(separator: " · ")
    }

    private func badgeColor(_ badge: ReelFilmBadge) -> Color {
        switch badge {
        case .draft: return .secondary
        case .withAgent: return .blue
        case .approvedWaiting: return .orange
        case .rendered: return .green
        }
    }

    @ViewBuilder
    private func rows(for folder: ReelFilmFolder) -> some View {
        ForEach(folder.films) { film in
            HStack(spacing: 12) {
                ReelThumbnailView(url: film.url, width: film.width, height: film.height)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(film.formatLabel) · \(ReelLibrary.durationText(film.duration))").font(.body.weight(.medium))
                    Text("\(film.width)×\(film.height) · \(Self.dateFormatter.string(from: film.modifiedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(film.url.lastPathComponent).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Spela", systemImage: "play.fill") { play(film, in: folder) }
                    .buttonStyle(.borderedProminent)
                Button("Visa i Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([film.url])
                }
                FilmShareButton(url: film.url)
            }
            .controlSize(.small)
            .padding(.vertical, 2)
        }
        ForEach(model.serverOnlyRenders(for: folder)) { render in
            HStack(spacing: 12) {
                Image(systemName: "icloud").font(.title2).frame(width: 64).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(render.formatLabel ?? render.outputId)\(render.duration.map { " · " + ReelLibrary.durationText($0) } ?? "")")
                        .font(.body.weight(.medium))
                    Text("Finns bara på servern (revision \(render.revision))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Spela", systemImage: "play.fill") {
                    openWindow(id: ReelPlayerWindow.id, value: ReelPlayerRequest.remote(
                        render: render, in: folder, outputDirectory: outputDirectory))
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.vertical, 2)
        }
    }

    private func play(_ film: ReelFilm, in folder: ReelFilmFolder) {
        openWindow(id: ReelPlayerWindow.id, value: ReelPlayerRequest.local(
            film: film, in: folder, outputDirectory: outputDirectory))
    }
}

/// Miniatyr ur filmen (bildrutan vid 1 s), i filmens proportioner.
struct ReelThumbnailView: View {
    let url: URL
    let width: Int
    let height: Int

    @State private var image: NSImage?

    var body: some View {
        let ratio = width > 0 && height > 0 ? Double(width) / Double(height) : 16.0 / 9
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            if let cg = await ReelThumbnailer.thumbnail(for: url) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}

/// "Dela": systemets delningsmeny (`NSSharingServicePicker`) med filmen som fil.
struct FilmShareButton: View {
    let url: URL
    @State private var anchor: NSView?

    var body: some View {
        Button("Dela", systemImage: "square.and.arrow.up") {
            guard let anchor else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
        }
        .background(ShareAnchor(view: $anchor))
    }
}
