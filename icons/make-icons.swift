// Simgeleri üretir: swift icons/make-icons.swift  (proje kökünden)
// Çıktı: build/AppIcon.icns, tv/res/mipmap-xxxhdpi/ic_launcher.png, tv/res/drawable-xhdpi/banner.png
import AppKit

func png(_ w: Int, _ h: Int, _ draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func background(_ r: CGRect, radius: CGFloat) {
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    NSGradient(starting: NSColor(red: 0.40, green: 0.25, blue: 0.95, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.70, blue: 0.95, alpha: 1))!.draw(in: path, angle: -50)
}

func symbol(_ name: String, in r: CGRect) {
    let cfg = NSImage.SymbolConfiguration(pointSize: r.height, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let s = img.size, k = min(r.width / s.width, r.height / s.height)
    img.draw(in: CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k))
}

func icon(_ size: Int, macInset: Bool) -> Data {
    png(size, size) { r in
        let card = macInset ? r.insetBy(dx: r.width * 0.098, dy: r.height * 0.098) : r // macOS ızgarası: kenarda boşluk
        background(card, radius: card.width * 0.225)
        symbol("tv", in: card.insetBy(dx: card.width * 0.22, dy: card.height * 0.22))
    }
}

let fm = FileManager.default
try fm.createDirectory(atPath: "build/AppIcon.iconset", withIntermediateDirectories: true)
try fm.createDirectory(atPath: "tv/res/mipmap-xxxhdpi", withIntermediateDirectories: true)
try fm.createDirectory(atPath: "tv/res/drawable-xhdpi", withIntermediateDirectories: true)

for s in [16, 32, 128, 256, 512] {
    try icon(s, macInset: true).write(to: URL(fileURLWithPath: "build/AppIcon.iconset/icon_\(s)x\(s).png"))
    try icon(s * 2, macInset: true).write(to: URL(fileURLWithPath: "build/AppIcon.iconset/icon_\(s)x\(s)@2x.png"))
}
try icon(192, macInset: false).write(to: URL(fileURLWithPath: "tv/res/mipmap-xxxhdpi/ic_launcher.png"))

// TV ana ekran kartı (320x180 xhdpi)
try png(320, 180) { r in
    background(r, radius: 0)
    symbol("tv", in: CGRect(x: 24, y: 50, width: 90, height: 80))
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.white]
    NSAttributedString(string: "Ekran\nYansıt", attributes: attrs).draw(in: CGRect(x: 132, y: 40, width: 180, height: 100))
}.write(to: URL(fileURLWithPath: "tv/res/drawable-xhdpi/banner.png"))
print("simgeler hazır")
