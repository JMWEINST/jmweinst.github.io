import Cocoa
import ApplicationServices

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func names(_ e: AXUIElement) -> [String] {
    var n: CFArray?
    AXUIElementCopyAttributeNames(e, &n)
    return (n as? [String]) ?? []
}
func dump(_ e: AXUIElement, _ depth: Int, _ maxDepth: Int) {
    let role = attr(e, "AXRole") as? String ?? "?"
    let title = attr(e, "AXTitle") as? String ?? ""
    let url = attr(e, "AXURL").map { "\($0)" } ?? ""
    let fn = attr(e, "AXFilename") as? String ?? ""
    var pos = CGPoint.zero, size = CGSize.zero
    if let p = attr(e, "AXPosition") { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    if let s = attr(e, "AXSize") { AXValueGetValue(s as! AXValue, .cgSize, &size) }
    print(String(repeating: "  ", count: depth) + "\(role) title=\(title) fn=\(fn) url=\(url) frame=\(pos) \(size)")
    if depth == 2 { print(String(repeating: "  ", count: depth) + "  attrs: \(names(e))") }
    guard depth < maxDepth, let kids = attr(e, "AXChildren") as? [AXUIElement] else { return }
    for k in kids.prefix(12) { dump(k, depth + 1, maxDepth) }
}

print("trusted:", AXIsProcessTrusted())
print("screens:", NSScreen.screens.map { $0.frame })
guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
    print("no finder"); exit(0)
}
let app = AXUIElementCreateApplication(finder.processIdentifier)
dump(app, 0, 5)

// hit test at centre of the probe file, if we can find it
func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
    if let fn = attr(e, "AXFilename") as? String, fn.hasPrefix("morph-probe") { return e }
    if let t = attr(e, "AXTitle") as? String, t.hasPrefix("morph-probe") { return e }
    guard depth < 6, let kids = attr(e, "AXChildren") as? [AXUIElement] else { return nil }
    for k in kids { if let f = find(k, depth + 1) { return f } }
    return nil
}
if let el = find(app, 0) {
    var pos = CGPoint.zero, size = CGSize.zero
    if let p = attr(el, "AXPosition") { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    if let s = attr(el, "AXSize") { AXValueGetValue(s as! AXValue, .cgSize, &size) }
    print("FOUND probe element at", pos, size, "attrs:", names(el))
    var settable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(el, "AXPosition" as CFString, &settable)
    print("AXPosition settable:", settable)
    let sys = AXUIElementCreateSystemWide()
    var hit: AXUIElement?
    let r = AXUIElementCopyElementAtPosition(sys, Float(pos.x + size.width / 2), Float(pos.y + size.height / 2), &hit)
    print("hit result:", r.rawValue)
    if let h = hit {
        var pid: pid_t = 0; AXUIElementGetPid(h, &pid)
        print("hit pid:", pid, "finder pid:", finder.processIdentifier)
        var cur: AXUIElement? = h
        var i = 0
        while let c = cur, i < 8 {
            print("  up\(i):", attr(c, "AXRole") as? String ?? "?", attr(c, "AXURL").map { "\($0)" } ?? "-", attr(c, "AXFilename") as? String ?? "-")
            cur = attr(c, "AXParent").map { $0 as! AXUIElement }
            i += 1
        }
    }
} else { print("probe element NOT found") }
print("tap test:", CGPreflightListenEventAccess(), CGPreflightPostEventAccess())
