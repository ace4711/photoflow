import SwiftUI
import AppKit

/// Gemensam zoom och panorering för alla bilder i jämförelsen. Skalan är relativ till "anpassa till
/// rutan" (1 = hela bilden syns) och förskjutningen är en andel av den anpassade bildstorleken, så att
/// två rutor med olika pixelstorlek (eller en beskuren Lightroom-bild) visar samma ställe.
@MainActor @Observable
final class CompareViewport {
    static let maxScale: CGFloat = 64

    var scale: CGFloat = 1
    /// Bildens mittpunkt relativt rutans mitt, i andelar av den anpassade bildstorleken.
    var offset: CGSize = .zero

    var isFit: Bool { scale <= 1.001 }

    func reset() {
        scale = 1
        offset = .zero
    }

    /// Zoomar med `factor` så att punkten under markören (`anchor`, andelar av anpassad bildstorlek
    /// räknat från rutans mitt) ligger kvar.
    func zoom(by factor: CGFloat, anchor: CGPoint = .zero) {
        setScale(scale * factor, anchor: anchor)
    }

    func setScale(_ newScale: CGFloat, anchor: CGPoint = .zero) {
        let target = min(max(newScale, 1), Self.maxScale)
        guard target != scale else { return }
        let ratio = target / scale
        offset = CGSize(width: anchor.x - (anchor.x - offset.width) * ratio,
                        height: anchor.y - (anchor.y - offset.height) * ratio)
        scale = target
        clamp()
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        guard scale > 1.001 else { return }
        offset.width += dx
        offset.height += dy
        clamp()
    }

    /// Håller bilden täckande: man kan inte dra ut den ur rutan.
    func clamp() {
        if scale <= 1.001 {
            offset = .zero
            return
        }
        let limit = (scale - 1) / 2 + 0.05
        offset.width = min(max(offset.width, -limit), limit)
        offset.height = min(max(offset.height, -limit), limit)
    }

    /// Anpassad bildstorlek (punkter) för en bild med bredd/höjd-förhållandet `aspect` i en ruta.
    static func fitSize(aspect: CGFloat, in container: CGSize) -> CGSize {
        guard aspect > 0, container.width > 0, container.height > 0 else { return .zero }
        if container.width / container.height > aspect {
            return CGSize(width: container.height * aspect, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / aspect)
    }
}

/// Osynligt lager som fångar mus och styrplatta: dra = panorera, rullning = panorera, ⌥/⌘ + rullning
/// eller nypning = zooma, dubbelklick = anpassa/100 %.
struct CompareInteractionLayer: NSViewRepresentable {
    let viewport: CompareViewport
    /// Bildens bredd/höjd (för att veta hur stor den anpassade bilden är i rutan).
    let aspect: CGFloat
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> InteractionView {
        let v = InteractionView()
        v.viewport = viewport
        return v
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        nsView.viewport = viewport
        nsView.aspect = aspect
        nsView.onDoubleClick = onDoubleClick
    }

    final class InteractionView: NSView {
        var viewport: CompareViewport?
        var aspect: CGFloat = 1.5
        var onDoubleClick: () -> Void = {}
        private var lastDrag: CGPoint?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var fit: CGSize { CompareViewport.fitSize(aspect: aspect, in: bounds.size) }

        /// Markörens läge i andelar av den anpassade bildstorleken från rutans mitt.
        private func anchor(for event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow, from: nil)
            let f = fit
            guard f.width > 0, f.height > 0 else { return .zero }
            return CGPoint(x: (p.x - bounds.midX) / f.width, y: (p.y - bounds.midY) / f.height)
        }

        override func scrollWheel(with event: NSEvent) {
            guard let viewport else { return }
            let f = fit
            guard f.width > 0, f.height > 0 else { return }
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
                let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05))
                viewport.zoom(by: factor, anchor: anchor(for: event))
            } else {
                viewport.pan(dx: event.scrollingDeltaX / f.width, dy: event.scrollingDeltaY / f.height)
            }
        }

        override func magnify(with event: NSEvent) {
            viewport?.zoom(by: 1 + event.magnification, anchor: anchor(for: event))
        }

        override func mouseDown(with event: NSEvent) {
            lastDrag = convert(event.locationInWindow, from: nil)
            if event.clickCount == 2 { onDoubleClick() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let viewport, let last = lastDrag else { return }
            let p = convert(event.locationInWindow, from: nil)
            let f = fit
            if f.width > 0, f.height > 0 {
                viewport.pan(dx: (p.x - last.x) / f.width, dy: (p.y - last.y) / f.height)
            }
            lastDrag = p
        }

        override func mouseUp(with event: NSEvent) { lastDrag = nil }
    }
}

/// Ritar en bild enligt den gemensamma vyn. Canvas ritar bara det synliga, så extrem zoom blir inte dyr.
struct CompareImageCanvas: View {
    let image: CGImage?
    let viewport: CompareViewport
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            guard let image else { return }
            let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
            let fit = CompareViewport.fitSize(aspect: aspect, in: size)
            let w = fit.width * viewport.scale, h = fit.height * viewport.scale
            let rect = CGRect(x: size.width / 2 - w / 2 + viewport.offset.width * fit.width,
                              y: size.height / 2 - h / 2 + viewport.offset.height * fit.height,
                              width: w, height: h)
            // Närmaste granne när en bildpunkt täcker mer än en och en halv skärmpixel.
            let pixelsOnScreen = w * displayScale / CGFloat(max(image.width, 1))
            let img = Image(decorative: image, scale: 1).interpolation(pixelsOnScreen > 1.5 ? .none : .high)
            context.draw(context.resolve(img), in: rect)
        }
    }
}
