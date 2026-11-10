// Clipboard.swift: the macOS side of the shared clipboard. Everything here runs on the main queue.

import AppKit

let jpegType = NSPasteboard.PasteboardType("public.jpeg")
let bmpType = NSPasteboard.PasteboardType("com.microsoft.bmp")
let utf8Type = NSPasteboard.PasteboardType("public.utf8-plain-text")   // == .string

/// Data the guest received from the host, ready to put on the pasteboard.
struct HostClip {
    var text: String?
    var png: Data?
    var isEmpty: Bool { text == nil && png == nil }
}

final class Pasteboard {
    private let pb = NSPasteboard.general

    var changeCount: Int { pb.changeCount }

    /// Which VD_AGENT_CLIPBOARD types the current guest pasteboard can be offered as.
    func offerTypes() -> [UInt32] {
        guard let types = pb.types, !types.isEmpty else { return [] }
        var out: [UInt32] = []
        if types.contains(.string) { out.append(ClipType.utf8Text) }
        // A Finder file copy also carries the file's icon as TIFF; offering that as an image
        // would paste an icon, so file copies only offer their text (the file name).
        if !types.contains(.fileURL),
           types.contains(where: { [.png, .tiff, jpegType, bmpType].contains($0) }) {
            out.append(ClipType.png)
        }
        return out
    }

    /// Current pasteboard content in the requested wire type, or nil if it is not available.
    func read(type: UInt32) -> Data? {
        switch type {
        case ClipType.utf8Text:
            guard let s = pb.string(forType: .string) else { return nil }
            return Data(s.utf8)
        case ClipType.png:
            if let png = pb.data(forType: .png) { return png }
            for t in [NSPasteboard.PasteboardType.tiff, jpegType, bmpType] {
                if let d = pb.data(forType: t), let png = Pasteboard.toPNG(d) { return png }
            }
            return nil
        default:
            return nil
        }
    }

    /// Replace the pasteboard with host data; returns the resulting changeCount.
    func write(_ clip: HostClip) -> Int {
        pb.clearContents()
        let item = NSPasteboardItem()
        if let t = clip.text { item.setString(t, forType: .string) }
        // PNG only: the pasteboard server converts it to TIFF for readers that ask for TIFF.
        if let png = clip.png { item.setData(png, forType: .png) }
        pb.writeObjects([item])
        return pb.changeCount
    }

    /// Decode any image format ImageIO knows (PNG, BMP, JPEG, TIFF) and re-encode it as PNG.
    static func toPNG(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Wire data for an incoming clipboard type, converted to what we put on the pasteboard.
    static func decode(type: UInt32, data: Data) -> HostClip? {
        switch type {
        case ClipType.utf8Text:
            var d = data
            while d.last == 0 { d.removeLast() }   // some clients send a trailing NUL
            guard let s = String(data: d, encoding: .utf8) else {
                log("host text is not valid UTF-8; ignored")
                return nil
            }
            return HostClip(text: s, png: nil)
        case ClipType.png:
            // Check it decodes, so a broken image never reaches the pasteboard.
            guard NSBitmapImageRep(data: data) != nil else { log("host PNG does not decode; ignored"); return nil }
            return HostClip(text: nil, png: data)
        case ClipType.bmp, ClipType.jpg, ClipType.tiff:
            guard let png = toPNG(data) else { log("host image type \(type) does not decode; ignored"); return nil }
            return HostClip(text: nil, png: png)
        default:
            return nil
        }
    }
}
