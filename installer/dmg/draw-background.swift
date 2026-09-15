// рисует фон окна DMG: заголовок, стрелка от приложения к «Программам» и подсказка про инструкцию
// запуск: swift installer/dmg/draw-background.swift installer/dmg/background.tiff
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift draw-background.swift <background.tiff>\n".utf8))
    exit(2)
}

/// окно Finder в точках; картинка рисуется вдвое плотнее для Retina
let window = CGSize(width: 640, height: 440)
let density: CGFloat = 2

guard let canvas = CGContext(data: nil, width: Int(window.width * density), height: Int(window.height * density),
                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("bitmap context unavailable\n".utf8))
    exit(1)
}
canvas.scaleBy(x: density, y: density)
// дальше координаты сверху вниз, как в раскладке icon_locations
canvas.translateBy(x: 0, y: window.height)
canvas.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: true)

canvas.setFillColor(CGColor(srgbRed: 0.96, green: 0.965, blue: 0.98, alpha: 1))
canvas.fill(CGRect(origin: .zero, size: window))

func caption(_ text: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, shade: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(white: shade, alpha: 1),
        .paragraphStyle: paragraph,
    ]).draw(in: CGRect(x: 20, y: top, width: window.width - 40, height: size * 1.5))
}

caption("Lidfold", top: 34, size: 30, weight: .bold, shade: 0.12)
caption("Перетащите значок в папку «Программы»", top: 84, size: 16, weight: .regular, shade: 0.36)
caption("Как открыть в первый раз и дать доступ к экрану, написано в файле «Установка»", top: 396,
        size: 13, weight: .regular, shade: 0.42)

// стрелка между значками приложения и «Программ»
let shaft = CGRect(x: 282, y: 208.5, width: 64, height: 3)
canvas.setFillColor(CGColor(srgbRed: 0.2, green: 0.36, blue: 0.82, alpha: 1))
canvas.addPath(CGPath(roundedRect: shaft, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
canvas.fillPath()
canvas.move(to: CGPoint(x: 362, y: 210))
canvas.addLine(to: CGPoint(x: 344, y: 199))
canvas.addLine(to: CGPoint(x: 344, y: 221))
canvas.closePath()
canvas.fillPath()

guard let picture = canvas.makeImage() else {
    FileHandle.standardError.write(Data("image not produced\n".utf8))
    exit(1)
}
// размер в точках говорит Finder, что пикселей вдвое больше, чем точек окна
let retina = NSBitmapImageRep(cgImage: picture)
retina.size = window
guard let tiff = retina.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw]) else {
    FileHandle.standardError.write(Data("tiff encoding failed\n".utf8))
    exit(1)
}
try tiff.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
