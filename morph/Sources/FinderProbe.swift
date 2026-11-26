import ApplicationServices
import Cocoa

/// A file under the pointer, and where its icon or row is on screen (top-left origin, like the pointer).
struct FileHit {
    let url: URL
    let frame: CGRect?
}

func axValue(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func axString(_ element: AXUIElement, _ name: String) -> String {
    (axValue(element, name) as? String) ?? ""
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (axValue(element, "AXChildren") as? [AXUIElement]) ?? []
}

func axParent(_ element: AXUIElement) -> AXUIElement? {
    guard let value = axValue(element, "AXParent"), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = axValue(element, "AXPosition"), let s = axValue(element, "AXSize"),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

/// Asks Finder, through the accessibility API, which file is at a point on screen.
enum FinderProbe {
    static let system: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.4)
        return element
    }()

    static let containers: Set<String> = [
        "AXApplication", "AXWindow", "AXScrollArea", "AXOutline", "AXBrowser", "AXList", "AXTable",
        "AXSplitGroup", "AXToolbar", "AXMenuBar", "AXMenu", "AXMenuItem", "AXSheet",
    ]

    /// A real, existing, regular file named by this element (folders and apps don't count).
    static func fileURL(_ element: AXUIElement) -> URL? {
        guard let value = axValue(element, "AXURL") else { return nil }
        var url = value as? URL
        if url == nil, let s = value as? String { url = URL(string: s) }
        // Finder hands out "file reference" URLs (file:///.file/id=…); turn them into real paths.
        guard let found = url, found.isFileURL, let path = (found as NSURL).filePathURL else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return path
    }

    static func firstFile(in element: AXUIElement, depth: Int) -> URL? {
        if let url = fileURL(element) { return url }
        guard depth > 0 else { return nil }
        for child in axChildren(element).prefix(24) {
            if let url = firstFile(in: child, depth: depth - 1) { return url }
        }
        return nil
    }

    static func file(at point: CGPoint) -> FileHit? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success,
              let hit = found else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" else { return nil }

        // 1. The thing under the pointer, or something just above it, is a file (icons, names).
        var chain: [AXUIElement] = []
        var current: AXUIElement? = hit
        while let element = current, chain.count < 6 {
            let role = axString(element, "AXRole")
            if containers.contains(role) { break }
            if let url = fileURL(element) { return FileHit(url: url, frame: axFrame(element)) }
            chain.append(element)
            current = axParent(element)
        }

        // 2. Somewhere on a list or column row: the row knows its file even if this cell doesn't.
        for element in chain where ["AXRow", "AXCell"].contains(axString(element, "AXRole")) {
            if let url = firstFile(in: element, depth: 3) { return FileHit(url: url, frame: axFrame(element)) }
        }

        // 3. Just off the icon, on its name: pick the icon whose label area contains the pointer.
        for element in [hit] + chain.prefix(2) where axString(element, "AXRole") == "AXGroup" {
            for child in axChildren(element).prefix(600) {
                guard let frame = axFrame(child), frame.width <= 256 else { continue }
                let label = CGRect(x: frame.minX - 22, y: frame.minY - 4, width: frame.width + 44, height: frame.height + 44)
                if label.contains(point), let url = fileURL(child) { return FileHit(url: url, frame: frame) }
            }
            break
        }
        return nil
    }
}
