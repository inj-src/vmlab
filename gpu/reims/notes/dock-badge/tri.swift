// tri.swift FILTER [PX]: one window with one layer: a PX-pixel white "7" on red shown at 80 points,
// minified with FILTER (linear | trilinear | nearest).
import AppKit
let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "trilinear"
let px = CGFloat(CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 512)
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 600, width: 240, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = filter
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 140)); view.wantsLayer = true
        view.layer!.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        window.contentView = view
        let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
            NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1).setFill(); NSBezierPath(ovalIn: r).fill()
            let s = NSAttributedString(string: "7", attributes: [.font: NSFont.systemFont(ofSize: px * 0.6, weight: .semibold), .foregroundColor: NSColor.white])
            let b = s.size(); s.draw(at: NSPoint(x: (r.width - b.width) / 2, y: (r.height - b.height) / 2)); return true
        }
        var rect = NSRect(x: 0, y: 0, width: px, height: px)
        let l = CALayer(); l.frame = CGRect(x: 80, y: 30, width: 80, height: 80)
        l.contents = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        l.contentsGravity = .resizeAspect
        l.minificationFilter = filter == "linear" ? .linear : filter == "nearest" ? .nearest : .trilinear
        view.layer!.addSublayer(l)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let delegate = Delegate(); app.delegate = delegate; app.run()
