// TTS's icon: the sound of «Text to speech» as the author says it, in STT's bar grammar (STT is its pair).
// Usage: icon <dir> <wave.svg> writes <dir>/light.png, <dir>/dark.png and the svg; ./build turns them into an
// Icon Composer icon (macOS 26+ switches it with the theme) through actool.
//
// Heights: measured over 32 recorded takes of the author's voice (2026-11-09): three syllables, three bars each (the loudest moment of
// each third), the median across takes, tallest 576, steps of 32 on the old 824 px plate, a quiet bar of 96 between
// words and nothing lower. Not reversed, not mirrored: the wave as it was said.
// Bar = gap = 32, one device pixel at 16 pt on Retina, as STT.
import AppKit

let heights: [CGFloat] = [576, 512, 96, 96, 256, 256, 96, 96, 224, 224, 96]
let tallest: CGFloat = 576, bar: CGFloat = 32, pitch: CGFloat = 64
let left = 512 - pitch * CGFloat(heights.count - 1) / 2 - bar / 2

// light: bars #1C1C1E, dark: white, on the system's own plate (as STT).
func draw(_ light: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let c = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    c.scaleBy(x: 1024 / 824, y: 1024 / 824); c.translateBy(x: -100, y: -100)
    c.setFillColor(light ? CGColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1) : .white)
    for (i, h) in heights.enumerated() {
        let r = CGRect(x: left + CGFloat(i) * pitch, y: 512 - h / 2, width: bar, height: h)
        c.addPath(CGPath(roundedRect: r, cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
    }
    c.fillPath()
    return rep
}

let out = CommandLine.arguments[1]
for (n, light) in [("light", true), ("dark", false)] {
    try! draw(light).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(n).png"))
}

let w = pitch * CGFloat(heights.count - 1) + bar
var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(Int(w)) \(Int(tallest))\" fill=\"currentColor\">"
for (i, h) in heights.enumerated() {
    svg += "<rect x=\"\(Int(CGFloat(i) * pitch))\" y=\"\(Int((tallest - h) / 2))\" width=\"\(Int(bar))\" height=\"\(Int(h))\" rx=\"\(Int(bar / 2))\"/>"
}
try! (svg + "</svg>\n").write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
