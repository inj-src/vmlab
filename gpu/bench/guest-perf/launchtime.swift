// launchtime APP_PATH [ROUNDS]: time from asking macOS to open an app until its first normal
// window is on screen. Each round: launch, wait for the window, quit, wait for exit.
import AppKit
import CoreGraphics

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func hasWindow(_ pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid,
              (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let width = b["Width"] as? Double, let height = b["Height"] as? Double else { continue }
        if width >= 200 && height >= 100 { return true }
    }
    return false
}
let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
let rounds = args.count > 2 ? Int(args[2])! : 3
var out: [String] = []
for _ in 0..<rounds {
    let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
    var app: NSRunningApplication?
    var launched = 0.0
    let t0 = now()
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { a, _ in app = a; launched = now(); sem.signal() }
    sem.wait()
    guard let a = app else { out.append("failed"); continue }
    var shown = 0.0
    while now() - t0 < 60 { if hasWindow(a.processIdentifier) { shown = now(); break }; usleep(20_000) }
    out.append(String(format: "process %.2f s, window %.2f s", launched - t0, shown > 0 ? shown - t0 : -1))
    sleep(2)
    a.terminate(); var n = 0
    while !a.isTerminated && n < 100 { usleep(100_000); n += 1 }
    if !a.isTerminated { a.forceTerminate() }
    sleep(2)
}
print(url.lastPathComponent + ": " + out.joined(separator: " | "))
