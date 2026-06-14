import AppKit
import Foundation

enum IconError: Error, CustomStringConvertible {
    case invalidArguments
    case cannotLoadSource(URL)
    case cannotRenderPNG(URL)
    case iconutilFailed(Int32)

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: swift scripts/render-app-icon.swift <output.icns> [source.png]"
        case .cannotLoadSource(let url):
            return "cannot load icon source: \(url.path)"
        case .cannotRenderPNG(let url):
            return "cannot render PNG: \(url.path)"
        case .iconutilFailed(let status):
            return "iconutil failed with exit status \(status)"
        }
    }
}

func render(_ source: NSImage, edge: Int) -> NSImage {
    let size = NSSize(width: edge, height: edge)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(origin: .zero, size: size),
                from: NSRect(origin: .zero, size: source.size),
                operation: .copy,
                fraction: 1)
    return image
}

func writePNG(source: NSImage, edge: Int, name: String, to iconset: URL) throws {
    let image = render(source, edge: edge)
    let output = iconset.appendingPathComponent(name)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw IconError.cannotRenderPNG(output)
    }
    try data.write(to: output)
}

do {
    guard (2...3).contains(CommandLine.arguments.count) else {
        throw IconError.invalidArguments
    }

    let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let sourceURL = CommandLine.arguments.count == 3
        ? URL(fileURLWithPath: CommandLine.arguments[2])
        : URL(fileURLWithPath: "Assets/AppIcon.png")

    guard let source = NSImage(contentsOf: sourceURL) else {
        throw IconError.cannotLoadSource(sourceURL)
    }

    let fm = FileManager.default
    try fm.createDirectory(at: outputURL.deletingLastPathComponent(),
                           withIntermediateDirectories: true)

    let iconset = fm.temporaryDirectory
        .appendingPathComponent("dependency-tend-\(UUID().uuidString).iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: iconset) }

    let entries: [(Int, String)] = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png")
    ]

    for entry in entries {
        try writePNG(source: source, edge: entry.0, name: entry.1, to: iconset)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw IconError.iconutilFailed(process.terminationStatus)
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
