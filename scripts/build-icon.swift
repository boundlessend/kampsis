// собирает набор AppIcon из мастер-картинки assets/icon-master.png
// запуск: swift scripts/build-icon.swift assets/icon-master.png Kampsis/Assets.xcassets/AppIcon.appiconset
import AppKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift scripts/build-icon.swift <master.png> <appiconset>\n".utf8))
    exit(2)
}
let masterURL = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let master = NSImage(contentsOf: masterURL), let tiff = master.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff), let source = rep.cgImage else {
    FileHandle.standardError.write(Data("не читается мастер: \(masterURL.path)\n".utf8))
    exit(1)
}
guard source.width == 1024, source.height == 1024 else {
    FileHandle.standardError.write(Data("мастер должен быть 1024x1024, получено \(source.width)x\(source.height)\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func scaled(to pixels: Int) -> Data {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("bitmap context unavailable for \(pixels) px")
    }
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let image = context.makeImage() else { fatalError("no image at \(pixels) px") }
    let png = NSBitmapImageRep(cgImage: image)
    png.size = NSSize(width: pixels, height: pixels)
    guard let data = png.representation(using: .png, properties: [:]) else { fatalError("no png at \(pixels) px") }
    return data
}

let points = [16, 32, 128, 256, 512]
var entries: [String] = []
for point in points {
    for scale in [1, 2] {
        let name = "icon-\(point)@\(scale)x.png"
        try scaled(to: point * scale).write(to: output.appendingPathComponent(name))
        entries.append("""
            {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(scale)x",
              "size" : "\(point)x\(point)"
            }
        """)
    }
}
let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try Data(contents.utf8).write(to: output.appendingPathComponent("Contents.json"))
print("иконка собрана: \(points.count * 2) файла в \(output.path)")
