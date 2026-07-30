import AppKit

/// Draws the menu bar item as a single NSImage.
///
/// `MenuBarExtra`'s label only renders `Text` and `Image` reliably; arbitrary
/// SwiftUI shapes silently come out blank. Producing the artwork ourselves also
/// buys template rendering, so the item inverts correctly against light and dark
/// menu bars and follows the system accent/tint rules.
enum MenuBarIcon {
    static let height: CGFloat = 16
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2
    private static let barHeight: CGFloat = 12
    private static let baseline: CGFloat = 2

    static func image(sources: [UsageSource],
                      worst: UsageWindow?,
                      showsWorstFigure: Bool) -> NSImage {
        if showsWorstFigure, let worst {
            return figure(usedPercent: worst.usedPercent)
        }
        return bars(sources: sources)
    }

    // MARK: - Mode A: one gauge per source

    private static func bars(sources: [UsageSource]) -> NSImage {
        let count = max(sources.count, 1)
        let width = CGFloat(count) * barWidth + CGFloat(count - 1) * barGap

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (index, source) in sources.enumerated() {
                let x = CGFloat(index) * (barWidth + barGap)
                // Draw the track first: a source sitting at 0% still needs to
                // read as present rather than as a missing bar.
                rounded(NSRect(x: x, y: baseline, width: barWidth, height: barHeight), alpha: 0.25)

                let fraction = clamp((source.worstWindow?.usedPercent ?? 0) / 100)
                rounded(NSRect(x: x, y: baseline,
                               width: barWidth,
                               height: max(1.5, barHeight * fraction)), alpha: 1)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Mode B: the one source running hot

    private static func figure(usedPercent: Double) -> NSImage {
        let text = "\(Int(usedPercent.rounded()))%"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attributes)

        let glyph: CGFloat = 10
        let gap: CGFloat = 3
        let width = glyph + gap + ceil(textSize.width)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let box = NSRect(x: 0, y: (height - glyph) / 2, width: glyph, height: glyph)

            let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.black.setStroke()
            ring.stroke()

            // Fill the dial from the bottom in proportion to consumption.
            NSGraphicsContext.saveGraphicsState()
            let fraction = clamp(usedPercent / 100)
            NSBezierPath(rect: NSRect(x: box.minX, y: box.minY,
                                      width: box.width,
                                      height: box.height * fraction)).setClip()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: box.insetBy(dx: 2, dy: 2)).fill()
            NSGraphicsContext.restoreGraphicsState()

            (text as NSString).draw(
                at: NSPoint(x: glyph + gap, y: (height - textSize.height) / 2),
                withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Helpers

    private static func rounded(_ rect: NSRect, alpha: CGFloat) {
        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }

    private static func clamp(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }

    /// Renders at `scale` against white so a black template image is inspectable.
    /// Used by `--icon`; not part of the running UI.
    static func png(_ image: NSImage, scale: CGFloat) -> Data? {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
