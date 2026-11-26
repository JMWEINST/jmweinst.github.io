import ApplicationServices
import Cocoa
import ServiceManagement

/// Which modifier keys have to be held while clicking a file.
enum Trigger: Int, CaseIterable {
    case option, controlOption, optionCommand

    var flags: CGEventFlags {
        switch self {
        case .option: return [.maskAlternate]
        case .controlOption: return [.maskControl, .maskAlternate]
        case .optionCommand: return [.maskAlternate, .maskCommand]
        }
    }

    var title: String {
        switch self {
        case .option: return "⌥ Option + Click"
        case .controlOption: return "⌃⌥ Control + Option + Click"
        case .optionCommand: return "⌥⌘ Option + Command + Click"
        }
    }

    var short: String {
        switch self {
        case .option: return "⌥ Option"
        case .controlOption: return "⌃⌥ Control + Option"
        case .optionCommand: return "⌥⌘ Option + Command"
        }
    }

    static var current: Trigger {
        get { Trigger(rawValue: UserDefaults.standard.integer(forKey: "trigger")) ?? .option }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "trigger") }
    }
}

/// Sees every left click before the app under the pointer does. A click with the trigger keys held,
/// on a file in Finder, is taken over to open the wheel; everything else passes straight through.
func morphEventTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    guard let app = AppDelegate.shared else { return pass }
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = app.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return pass
    case .leftMouseUp:
        if app.swallowMouseUp { app.swallowMouseUp = false; return nil }
        return pass
    case .leftMouseDown:
        let held = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
        guard !app.paused, !WheelController.shared.isVisible, held == Trigger.current.flags else { return pass }
        let point = event.location
        guard let hit = FinderProbe.file(at: point) else { return pass }
        app.swallowMouseUp = true
        DispatchQueue.main.async { WheelController.shared.show(hit, at: point) }
        return nil
    default:
        return pass
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    var tap: CFMachPort?
    var swallowMouseUp = false
    var paused = false
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Artwork.menuBarIcon()
        item.button?.toolTip = "Morph"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        if Debug.runGUIMode() { return }
        start()
    }

    // MARK: Permission and the click tap

    var trusted: Bool { AXIsProcessTrusted() }

    private func start() {
        if trusted {
            installTap()
            welcomeOnce()
            return
        }
        // Shows the system's own "Morph would like to control this computer" prompt.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(prompt)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self, self.trusted else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.installTap()
            self.welcomeOnce()
        }
    }

    private func installTap(attempt: Int = 0) {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: morphEventTap, userInfo: nil) else {
            // Right after permission is granted the system can take a moment to honour it.
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.installTap(attempt: attempt + 1) }
            }
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func welcomeOnce() {
        guard !UserDefaults.standard.bool(forKey: "welcomed") else { return }
        UserDefaults.standard.set(true, forKey: "welcomed")
        let alert = NSAlert()
        alert.messageText = "Morph is ready"
        alert.informativeText = """
        Hold \(Trigger.current.short) and click any file on your desktop or in a Finder window.

        Pick a kind of file, then the exact format. The file changes right where it is, and the \
        original goes to the Trash in case you want it back.

        Morph lives in the menu bar (the ring icon) if you want to pause it or change the shortcut.
        """
        alert.addButton(withTitle: "Got It")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, state: Bool = false, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = state ? .on : .off
            item.tag = tag
            menu.addItem(item)
            return item
        }

        if !trusted {
            _ = add("Morph needs Accessibility access to see files", nil)
            _ = add("Open Accessibility Settings…", #selector(openAccessibility))
        } else if tap == nil {
            _ = add("Starting up… (if this stays, quit and reopen Morph)", nil)
        } else {
            _ = add("Hold \(Trigger.current.short) and click a file", nil)
        }
        menu.addItem(.separator())
        _ = add("Pause Morph", #selector(togglePause), state: paused)

        let triggers = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for trigger in Trigger.allCases {
            let item = NSMenuItem(title: trigger.title, action: #selector(chooseTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.tag = trigger.rawValue
            item.state = trigger == Trigger.current ? .on : .off
            submenu.addItem(item)
        }
        triggers.submenu = submenu
        menu.addItem(triggers)

        if #available(macOS 13.0, *) {
            _ = add("Open at Login", #selector(toggleLogin), state: SMAppService.mainApp.status == .enabled)
        }
        menu.addItem(.separator())
        _ = add("Quit Morph", #selector(quit))
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func togglePause() { paused.toggle() }

    @objc private func chooseTrigger(_ sender: NSMenuItem) {
        if let trigger = Trigger(rawValue: sender.tag) { Trigger.current = trigger }
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login setting"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// The menu-bar glyph and the app icon, drawn in code so there are no image files to ship.
enum Artwork {
    static func ring(in ctx: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat, dot: CGFloat) {
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        for i in 0..<3 {
            let start = (90 - CGFloat(i) * 120 - 18) * .pi / 180
            let end = (90 - CGFloat(i + 1) * 120 + 18) * .pi / 180
            ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            ctx.strokePath()
        }
        ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
    }

    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ring(in: ctx, center: CGPoint(x: rect.midX, y: rect.midY), radius: 6.4, width: 2, dot: 2.1)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func appIcon(pixels: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(pixels)
        let plate = CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
        let shape = CGPath(roundedRect: plate, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let colors = [CGColor(srgbRed: 0.36, green: 0.30, blue: 0.98, alpha: 1),
                      CGColor(srgbRed: 0.09, green: 0.10, blue: 0.24, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY),
                                   end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
        }
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ring(in: ctx, center: CGPoint(x: s / 2, y: s / 2), radius: s * 0.235, width: s * 0.075, dot: s * 0.075)
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
