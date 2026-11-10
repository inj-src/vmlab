// Clipboard.swift: the macOS side of the shared clipboard. Everything here runs on the main queue.

import AppKit
import ImageIO
import UniformTypeIdentifiers

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
        if !types.contains(.fileURL), !imageTypes(types).isEmpty {
            out.append(ClipType.png)
        }
        return out
    }

    /// Pasteboard types holding an image (PNG, TIFF, JPEG, HEIC, GIF, BMP, PDF...), best first.
    private func imageTypes(_ types: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        let images = types.filter { UTType($0.rawValue)?.conforms(to: .image) == true || $0 == .pdf }
        return images.sorted { ($0 == .png ? 0 : 1) < ($1 == .png ? 0 : 1) }
    }

    /// Current pasteboard content in the requested wire type, or nil if it is not available.
    func read(type: UInt32) -> Data? {
        switch type {
        case ClipType.utf8Text:
            guard let s = pb.string(forType: .string) else { return nil }
            return Data(s.utf8)
        case ClipType.png:
            for t in imageTypes(pb.types ?? []) {
                guard let d = pb.data(forType: t) else { continue }
                if t == .png { return d }
                if let png = Pasteboard.toPNG(d) { return png }
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

    /// Decode any image format ImageIO knows (PNG, BMP, JPEG, TIFF, HEIC, GIF...) and re-encode
    /// it as PNG, with the EXIF orientation applied (a rotated phone photo stays upright).
    /// Vector data (PDF) goes through NSImage instead.
    static func toPNG(_ data: Data) -> Data? {
        if let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
           let image = orientedImage(src) {
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dst, image, nil)
            return CGImageDestinationFinalize(dst) ? out as Data : nil
        }
        guard let img = NSImage(data: data), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func orientedImage(_ src: CGImageSource) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if orientation == 1 { return CGImageSourceCreateImageAtIndex(src, 0, nil) }
        // The thumbnail API applies the orientation; ask for the full size.
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
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
