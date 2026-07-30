import AppKit

/// Draws the Finder/app icon, echoing the menu bar item so the two read as the
/// same thing: three gauges at different fills, each over its own track.
///
/// Generated rather than committed as a binary asset, so the geometry stays
/// reviewable and the whole set regenerates from one place.
enum AppIcon {
    /// Big Sur proportions: the artwork square is 824/1024 of the canvas with a
    /// 185.4/1024 corner radius. Rounded corners approximate macOS's continuous
    /// curve closely enough at these sizes.
    private static let plateInset: CGFloat = 100.0 / 1024
    private static let cornerRadius: CGFloat = 185.4 / 1024

    private static let barWidth: CGFloat = 0.140
    private static let barGap: CGFloat = 0.085
    private static let barAreaHeight: CGFloat = 0.560
    /// Rising left to right, the same silhouette as the menu bar gauges.
    private static let fills: [CGFloat] = [0.42, 0.66, 0.92]

    static func image(pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let s = CGFloat(pixels)
        draw(side: s)
        return rep
    }

    private static func draw(side s: CGFloat) {
        let inset = s * plateInset
        let plate = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let platePath = NSBezierPath(roundedRect: plate,
                                     xRadius: s * cornerRadius, yRadius: s * cornerRadius)

        NSGradient(colors: [
            NSColor(srgbRed: 0.36, green: 0.58, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 0.09, green: 0.27, blue: 0.80, alpha: 1),
        ])?.draw(in: platePath, angle: -90)

        // Bars are laid out against the plate, not the canvas, so the margins
        // stay proportional at every size.
        let unit = plate.width
        let totalWidth = unit * (barWidth * 3 + barGap * 2)
        let barW = unit * barWidth
        let gap = unit * barGap
        let trackH = unit * barAreaHeight
        let originX = plate.midX - totalWidth / 2
        let baseY = plate.midY - trackH / 2
        let radius = barW / 2

        for (index, fill) in fills.enumerated() {
            let x = originX + CGFloat(index) * (barW + gap)

            // The track is always drawn — the same rule the menu bar icon follows,
            // so an idle source still reads as present.
            NSColor(white: 1, alpha: 0.28).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: trackH),
                         xRadius: radius, yRadius: radius).fill()

            NSColor(white: 1, alpha: 0.97).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: trackH * fill),
                         xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// `LLMUsage --appicon <dir>` writes an .iconset directory for `iconutil`.
enum AppIconDump {
    /// The set `iconutil` expects; each logical size at 1x and 2x.
    private static let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    static func run(directory: String) -> Never {
        try? FileManager.default.createDirectory(atPath: directory,
                                                 withIntermediateDirectories: true)
        for variant in variants {
            guard let rep = AppIcon.image(pixels: variant.pixels),
                  let data = rep.representation(using: .png, properties: [:]) else { continue }
            let path = (directory as NSString).appendingPathComponent("\(variant.name).png")
            try? data.write(to: URL(fileURLWithPath: path))
        }
        print("\(directory)  \(variants.count) sizes")
        exit(0)
    }
}
