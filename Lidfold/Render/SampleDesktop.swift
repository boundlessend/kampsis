import AppKit

enum SampleDesktopFailure: LocalizedError {
    case contextUnavailable

    var errorDescription: String? { String(localized: "Couldn’t draw the sample desktop.") }
}

/// синтетический рабочий стол для предпросмотра: без скриншотов и сторонних изображений
@MainActor func drawSampleDesktop() throws -> CGImage {
    let size = CGSize(width: 1600, height: 1000)
    guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw SampleDesktopFailure.contextUnavailable
    }
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }

    paintWallpaper(context, size: size)
    paintMenuBar(context, width: size.width)
    paintNotesWindow(context, frame: CGRect(x: 130, y: 230, width: 640, height: 480))
    paintPhotoWindow(context, frame: CGRect(x: 840, y: 150, width: 600, height: 420))
    paintDock(context, center: size.width / 2, bottom: size.height - 24)

    guard let image = context.makeImage() else { throw SampleDesktopFailure.contextUnavailable }
    return image
}

private func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

private func paintWallpaper(_ context: CGContext, size: CGSize) {
    let base = CGGradient(colorsSpace: nil, colors: [rgb(0.13, 0.17, 0.46), rgb(0.18, 0.46, 0.72), rgb(0.55, 0.78, 0.86)] as CFArray,
                          locations: [0, 0.6, 1])
    if let base { context.drawLinearGradient(base, start: .zero, end: CGPoint(x: size.width, y: size.height), options: []) }
    for (center, radius, color) in [(CGPoint(x: 1250, y: 820), 620.0, rgb(0.95, 0.72, 0.86, 0.45)),
                                    (CGPoint(x: 260, y: 140), 520.0, rgb(0.45, 0.85, 0.95, 0.35))] {
        if let glow = CGGradient(colorsSpace: nil, colors: [color, rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1]) {
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }
}

private func paintMenuBar(_ context: CGContext, width: CGFloat) {
    context.setFillColor(rgb(1, 1, 1, 0.28))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 30))
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                     .foregroundColor: NSColor.white]
    (String(localized: "Notes     File     Edit     View     Window") as NSString).draw(at: CGPoint(x: 48, y: 6), withAttributes: attributes)
    (String(localized: "Tue 9:41") as NSString).draw(at: CGPoint(x: width - 90, y: 6), withAttributes: attributes)
}

private func paintWindowChrome(_ context: CGContext, frame: CGRect, title: String) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: rgb(0, 0, 0, 0.35))
    context.addPath(CGPath(roundedRect: frame, cornerWidth: 16, cornerHeight: 16, transform: nil))
    context.setFillColor(rgb(0.98, 0.98, 0.97))
    context.fillPath()
    context.restoreGState()
    for (index, color) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.79, 0.25)].enumerated() {
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: frame.minX + 20 + CGFloat(index) * 22, y: frame.minY + 17, width: 13, height: 13))
    }
    let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                          .foregroundColor: NSColor(white: 0.25, alpha: 1)]
    (title as NSString).draw(at: CGPoint(x: frame.minX + 100, y: frame.minY + 14), withAttributes: titleAttributes)
    context.setFillColor(rgb(0, 0, 0, 0.08))
    context.fill(CGRect(x: frame.minX, y: frame.minY + 46, width: frame.width, height: 1))
}

private func paintNotesWindow(_ context: CGContext, frame: CGRect) {
    paintWindowChrome(context, frame: frame, title: String(localized: "Notes"))
    let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .bold),
                                                  .foregroundColor: NSColor(white: 0.12, alpha: 1)]
    (String(localized: "Weekend Plans") as NSString).draw(at: CGPoint(x: frame.minX + 40, y: frame.minY + 78), withAttributes: heading)
    let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18),
                                               .foregroundColor: NSColor(white: 0.3, alpha: 1)]
    let items = [String(localized: "Buy paint for the balcony"), String(localized: "Call Grandma"),
                 String(localized: "Finish the book about mountains"), String(localized: "Pack for the trip"),
                 String(localized: "Sort the photos")]
    for (index, item) in items.enumerated() {
        let y = frame.minY + 150 + CGFloat(index) * 48
        context.setStrokeColor(rgb(0.7, 0.7, 0.7))
        context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(x: frame.minX + 42, y: y + 2, width: 20, height: 20))
        (item as NSString).draw(at: CGPoint(x: frame.minX + 78, y: y), withAttributes: body)
    }
}

private func paintPhotoWindow(_ context: CGContext, frame: CGRect) {
    paintWindowChrome(context, frame: frame, title: String(localized: "Lake.jpg"))
    let photo = CGRect(x: frame.minX, y: frame.minY + 47, width: frame.width, height: frame.height - 47)
    context.saveGState()
    context.addPath(CGPath(roundedRect: frame, cornerWidth: 16, cornerHeight: 16, transform: nil))
    context.clip()
    context.clip(to: photo)
    if let sky = CGGradient(colorsSpace: nil, colors: [rgb(0.98, 0.76, 0.52), rgb(0.62, 0.78, 0.93)] as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: photo.maxY), end: CGPoint(x: 0, y: photo.minY), options: [])
    }
    func ridge(_ points: [CGPoint], _ color: CGColor) {
        context.beginPath()
        context.move(to: CGPoint(x: photo.minX, y: photo.maxY))
        points.forEach { context.addLine(to: CGPoint(x: photo.minX + $0.x * photo.width, y: photo.minY + $0.y * photo.height)) }
        context.addLine(to: CGPoint(x: photo.maxX, y: photo.maxY))
        context.closePath()
        context.setFillColor(color)
        context.fillPath()
    }
    ridge([CGPoint(x: 0, y: 0.55), CGPoint(x: 0.22, y: 0.3), CGPoint(x: 0.42, y: 0.5), CGPoint(x: 0.7, y: 0.22), CGPoint(x: 1, y: 0.48)],
          rgb(0.36, 0.43, 0.6))
    ridge([CGPoint(x: 0, y: 0.7), CGPoint(x: 0.3, y: 0.52), CGPoint(x: 0.55, y: 0.66), CGPoint(x: 0.85, y: 0.5), CGPoint(x: 1, y: 0.62)],
          rgb(0.2, 0.36, 0.33))
    context.setFillColor(rgb(0.18, 0.5, 0.66))
    context.fill(CGRect(x: photo.minX, y: photo.minY + photo.height * 0.76, width: photo.width, height: photo.height * 0.24))
    context.restoreGState()
}

private func paintDock(_ context: CGContext, center: CGFloat, bottom: CGFloat) {
    let colors = [rgb(0.2, 0.55, 0.98), rgb(0.3, 0.8, 0.4), rgb(0.98, 0.6, 0.2), rgb(0.95, 0.3, 0.35),
                  rgb(0.6, 0.4, 0.95), rgb(0.98, 0.82, 0.25), rgb(0.5, 0.52, 0.56)]
    let tile: CGFloat = 64
    let gap: CGFloat = 14
    let width = CGFloat(colors.count) * (tile + gap) + gap
    let shelf = CGRect(x: center - width / 2, y: bottom - tile - 2 * gap, width: width, height: tile + 2 * gap)
    context.addPath(CGPath(roundedRect: shelf, cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.setFillColor(rgb(1, 1, 1, 0.3))
    context.fillPath()
    for (index, color) in colors.enumerated() {
        let rect = CGRect(x: shelf.minX + gap + CGFloat(index) * (tile + gap), y: shelf.minY + gap, width: tile, height: tile)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 15, cornerHeight: 15, transform: nil))
        context.setFillColor(color)
        context.fillPath()
    }
}
