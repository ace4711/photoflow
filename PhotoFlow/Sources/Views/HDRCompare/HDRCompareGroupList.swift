import SwiftUI

/// Vänsterlistan: grupper med miniatyr, kategori och status.
struct HDRCompareGroupList: View {
    @Bindable var model: HDRCompareModel

    var body: some View {
        List(selection: $model.selectedGroupID) {
            ForEach(model.groups) { group in
                row(group).tag(group.id)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.groups.isEmpty {
                ContentUnavailableView("Inga grupper", systemImage: "photo.stack")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("\(model.ratedCount) av \(model.groups.count) bedömda")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(6)
                .background(.bar)
        }
    }

    private func row(_ group: HDRCompareManifest.Group) -> some View {
        HStack(spacing: 8) {
            Group {
                if let thumb = model.thumbnails[group.id] {
                    Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 56, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.id).font(.callout.weight(.medium)).lineLimit(1)
                Text(HDRCompareCategory.title(group.category)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                status(group)
            }
            Spacer(minLength: 0)
        }
        .task(id: group.id) { await model.loadThumbnail(for: group) }
    }

    @ViewBuilder
    private func status(_ group: HDRCompareManifest.Group) -> some View {
        if model.isRated(group) {
            Label("bedömd", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        } else if let missing = model.missingText(group) {
            Label(missing, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
        } else {
            Text("ej bedömd").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
