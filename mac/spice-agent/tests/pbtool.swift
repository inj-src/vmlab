// pbtool: pasteboard helper for the tests (pbcopy/pbpaste only handle text).
//   pbtool count                         print changeCount
//   pbtool types                         print the pasteboard types, one per line
//   pbtool read <uti> <file>             write the data for <uti> to <file> (exit 1 if absent)
//   pbtool write <uti> <file> [...]      clear the pasteboard and put each <uti>/<file> pair on it
//   pbtool clear                         empty the pasteboard (no types at all)
import AppKit

let pb = NSPasteboard.general
let a = CommandLine.arguments
func die(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

switch a.count > 1 ? a[1] : "" {
case "count":
    print(pb.changeCount)
case "types":
    (pb.types ?? []).forEach { print($0.rawValue) }
case "read" where a.count == 4:
    guard let d = pb.data(forType: NSPasteboard.PasteboardType(a[2])) else { die("no \(a[2]) on the pasteboard") }
    do { try d.write(to: URL(fileURLWithPath: a[3])) } catch { die("\(error)") }
case "write" where a.count >= 4 && a.count % 2 == 0:
    pb.clearContents()
    let item = NSPasteboardItem()
    for i in stride(from: 2, to: a.count, by: 2) {
        guard let d = FileManager.default.contents(atPath: a[i + 1]) else { die("cannot read \(a[i + 1])") }
        item.setData(d, forType: NSPasteboard.PasteboardType(a[i]))
    }
    guard pb.writeObjects([item]) else { die("write failed") }
    print(pb.changeCount)
case "clear":
    pb.clearContents()
    print(pb.changeCount)
default:
    die("usage: pbtool count | types | read <uti> <file> | write <uti> <file> [<uti> <file>...] | clear")
}
