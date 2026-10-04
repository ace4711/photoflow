import SwiftUI
import AppKit

/// Visningsinställningar för stora bilden i granska-läget.
struct ReviewViewOptions: Equatable {
    var zoom100 = false
    var showClipping = false
}

/// Laddar en bild i (nästan) full upplösning utanför MainActor.
@MainActor
final class ReviewHiResLoader: ObservableObject {
    @Published var image: NSImage?
    private var loadedURL: URL?
    private var task: Task<Void, Never>?

    func load(_ url: URL?) {
        guard url != loadedURL else { return }
        task?.cancel()
        loadedURL = url
        image = nil
        guard let url else { return }
        task = Task {
            let img = await ImageLoader.downsampledImageAsync(at: url, maxDimension: 10000)
            guard !Task.isCancelled else { return }
            image = img
        }
    }

    deinit { task?.cancel() }
}

private func pixelSize(of image: NSImage) -> CGSize {
    if let rep = image.representations.first, rep.pixelsWide > 0 {
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    return image.size
}

/// Bilden i 100 % (en bildpunkt per skärmpunkt); dra för att panorera.
struct ReviewZoomView: View {
    let url: URL?
    @StateObject private var loader = ReviewHiResLoader()
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = loader.image {
                    let px = pixelSize(of: img)
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: px.width, height: px.height)
                        .offset(ReviewZoom.clampOffset(offset, image: px, viewport: geo.size))
                        .gesture(DragGesture()
                            .onChanged { v in
                                let base = dragStart ?? offset
                                dragStart = base
                                offset = ReviewZoom.clampOffset(
                                    CGSize(width: base.width + v.translation.width, height: base.height + v.translation.height),
                                    image: px, viewport: geo.size)
                            }
                            .onEnded { _ in dragStart = nil })
                } else {
                    ProgressView()
                }
                VStack {
                    Spacer()
                    HStack {
                        Text("100 % – dra för att panorera (Z: anpassa)")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .clipped()
        }
        .onAppear { loader.load(url) }
        .onChange(of: url) { _, new in offset = .zero; loader.load(new) }
    }
}

/// Lupp vid muspekaren när Shift hålls.
struct ReviewLoupeOverlay: View {
    let url: URL?
    var loupeSize: CGFloat = 220
    @StateObject private var loader = ReviewHiResLoader()
    @State private var pointer: CGPoint?
    @State private var shiftDown = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                if shiftDown, let pointer, let img = loader.image {
                    let px = pixelSize(of: img)
                    let fit = ReviewZoom.fitRect(container: geo.size, image: px)
                    if let n = ReviewZoom.normalizedPoint(pointer: pointer, fit: fit) {
                        let off = ReviewZoom.loupeOffset(normalized: n, imagePixels: px)
                        Image(nsImage: img)
                            .resizable()
                            .frame(width: px.width, height: px.height)
                            .offset(off)
                            .frame(width: loupeSize, height: loupeSize)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(radius: 6)
                            .position(x: pointer.x + loupeSize / 2 + 16, y: pointer.y - loupeSize / 2 - 16)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    pointer = p
                    let shift = NSEvent.modifierFlags.contains(.shift)
                    if shift != shiftDown { shiftDown = shift }
                    if shift { loader.load(url) }
                case .ended:
                    pointer = nil
                }
            }
        }
        .onChange(of: url) { _, _ in loader.load(nil) }
    }
}

/// Röd/blå klippoverlay och histogram, beräknat på nedskalad bild i bakgrunden.
struct ReviewClippingOverlay: View {
    let url: URL?
    @State private var result: HistogramResult?
    @State private var mask: CGImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let mask {
                Image(decorative: mask, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .allowsHitTesting(false)
            }
            if let result {
                ReviewHistogramView(result: result)
                    .padding(12)
            }
        }
        .task(id: url) {
            result = nil; mask = nil
            guard let url else { return }
            let analysed = await Task.detached(priority: .userInitiated) { () -> (HistogramResult, CGImage?)? in
                guard let r = ReviewImageAnalysis.analyze(url: url) else { return nil }
                return (r, ReviewImageAnalysis.maskImage(r))
            }.value
            guard !Task.isCancelled, let analysed else { return }
            result = analysed.0
            mask = analysed.1
        }
    }
}

struct ReviewHistogramView: View {
    let result: HistogramResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                let peak = max(result.bins.max() ?? 0, 0.0001)
                let w = size.width / CGFloat(result.bins.count)
                for (i, v) in result.bins.enumerated() {
                    let h = size.height * CGFloat(sqrt(v / peak))
                    ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: size.height - h, width: w, height: h)), with: .color(.white.opacity(0.85)))
                }
            }
            .frame(width: 192, height: 64)
            HStack(spacing: 10) {
                Label(percent(result.lowClipFraction), systemImage: "square.fill").foregroundStyle(.blue)
                Label(percent(result.highClipFraction), systemImage: "square.fill").foregroundStyle(.red)
            }
            .font(.caption2.monospacedDigit().bold())
            .labelStyle(.titleAndIcon)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.65)))
        .allowsHitTesting(false)
    }

    private func percent(_ f: Double) -> String {
        f < 0.0005 ? "0 %" : String(format: "%.1f %%", f * 100)
    }
}

extension View {
    /// Lägger zoom, klippvarning och lupp över en bildvy i granska-läget.
    func reviewImageOverlays(url: URL?, options: ReviewViewOptions) -> some View {
        self
            .overlay {
                if options.zoom100 { ReviewZoomView(url: url) }
            }
            .overlay {
                if options.showClipping && !options.zoom100 { ReviewClippingOverlay(url: url) }
            }
            .overlay {
                if !options.zoom100 { ReviewLoupeOverlay(url: url) }
            }
    }
}

/// Filterraden ovanför grupplistan.
struct ReviewFilterBar: View {
    @Binding var filter: ReviewFilter
    let addresses: [String]
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Alla") { filter = .all }
                Button("Ej granskade") { filter = .unreviewed }
                Button("Flaggade/avvisade") { filter = .flagged }
                Divider()
                Button("Skickas till redigering") { filter = .sending }
                Button("Ej vald för redigering") { filter = .notSending }
                Divider()
                ForEach(1...5, id: \.self) { n in
                    Button("★ \(n)+") { filter = .minRating(n) }
                }
                if !addresses.isEmpty {
                    Divider()
                    ForEach(addresses, id: \.self) { a in
                        Button(a) { filter = .address(a) }
                    }
                }
            } label: {
                Label(filter.title, systemImage: "line.3.horizontal.decrease.circle\(filter == .all ? "" : ".fill")")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            Spacer()
            if filter != .all {
                Text("\(visibleCount)/\(totalCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.bold())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
