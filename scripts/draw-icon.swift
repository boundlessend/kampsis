// рисует временную иконку приложения во все размеры набора AppIcon
// запуск: swift scripts/draw-icon.swift Kampsis/Assets.xcassets/AppIcon.appiconset
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/draw-icon.swift <appiconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func drawIcon(pixels: Int) -> Data {
    let canvas = CGFloat(pixels)
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("bitmap context unavailable for \(pixels) px")
    }
    context.scaleBy(x: canvas / 1024, y: canvas / 1024)

    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.3))
    context.addPath(platePath)
    context.setFillColor(color(0.1, 0.12, 0.24))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let base = CGGradient(colorsSpace: nil, colors: [color(0.2, 0.26, 0.58), color(0.07, 0.09, 0.2)] as CFArray,
                          locations: [0, 1])!
    context.drawLinearGradient(base, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // экран в перспективе: верх уже низа, как у прикрытой крышки
    let screen = CGMutablePath()
    screen.move(to: CGPoint(x: 232, y: 300))
    screen.addLine(to: CGPoint(x: 792, y: 300))
    screen.addLine(to: CGPoint(x: 712, y: 742))
    screen.addLine(to: CGPoint(x: 312, y: 742))
    screen.closeSubpath()
    context.saveGState()
    context.addPath(screen)
    context.clip()
    let glass = CGGradient(colorsSpace: nil,
                           colors: [color(0.93, 0.96, 1), color(0.62, 0.78, 0.98), color(0.24, 0.4, 0.78)] as CFArray,
                           locations: [0, 0.45, 1])!
    context.drawLinearGradient(glass, start: CGPoint(x: 512, y: 742), end: CGPoint(x: 512, y: 300), options: [])
    context.restoreGState()

    // петля под экраном
    context.addPath(CGPath(roundedRect: CGRect(x: 200, y: 246, width: 624, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
    context.setFillColor(color(0.78, 0.82, 0.92))
    context.fillPath()
    context.restoreGState()

    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("png encoding failed for \(pixels) px")
    }
    return png
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-\(points)@\(scale)x.png"
        try drawIcon(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("icon written to \(output.path)")
