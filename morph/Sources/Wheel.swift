import Cocoa

/// Where everything in the wheel sits. Angles are in degrees, counter-clockwise from 3 o'clock,
/// in a y-up space centred on the file. Shared by drawing, hit-testing and the tests.
struct WheelGeometry {
    static let centerRadius: CGFloat = 56
    static let ring1Inner: CGFloat = 60, ring1Outer: CGFloat = 122
    static let ring2Inner: CGFloat = 129, ring2Outer: CGFloat = 194
    static let extent: CGFloat = 206

    let groupCount: Int

    var groupSpan: CGFloat { 360 / CGFloat(max(groupCount, 1)) }

    /// Categories start at 12 o'clock and go clockwise.
    func groupAngle(_ index: Int) -> CGFloat { 90 - CGFloat(index) * groupSpan }

    /// The second ring fans out centred on its category: (angle of the first edge, width of each format).
    func fan(group: Int, formats: Int) -> (start: CGFloat, step: CGFloat) {
        let step = min(42, 360 / CGFloat(max(formats, 1)))
        return (groupAngle(group) + step * CGFloat(formats) / 2, step)
    }

    func formatAngle(group: Int, formats: Int, index: Int) -> CGFloat {
        let f = fan(group: group, formats: formats)
        return f.start - f.step * (CGFloat(index) + 0.5)
    }

    static func offset(angle: CGFloat, radius: CGFloat) -> CGPoint {
        let r = angle * .pi / 180
        return CGPoint(x: cos(r) * radius, y: sin(r) * radius)
    }

    static func normalized(_ angle: CGFloat) -> CGFloat {
        let m = angle.truncatingRemainder(dividingBy: 360)
        return m < 0 ? m + 360 : m
    }

    enum Target: Equatable {
        case group(Int)
        case format(Int)
    }

    /// What is at this offset from the centre, given which category (if any) is open.
    func target(at offset: CGPoint, openGroup: Int?, formats: Int) -> Target? {
        let distance = hypot(offset.x, offset.y)
        let angle = atan2(offset.y, offset.x) * 180 / .pi
        if distance >= Self.ring1Inner, distance < Self.ring1Outer + 3.5, groupCount > 0 {
            let index = Int(Self.normalized(90 + groupSpan / 2 - angle) / groupSpan)
            return .group(min(index, groupCount - 1))
        }
        if distance >= Self.ring1Outer + 3.5, distance <= Self.ring2Outer + 4, let open = openGroup, formats > 0 {
            let f = fan(group: open, formats: formats)
            let along = Self.normalized(f.start - angle)
            if along < f.step * CGFloat(formats) { return .format(min(Int(along / f.step), formats - 1)) }
        }
        return nil
    }
}

extension Category {
    var color: NSColor {
        switch self {
        case .image: return NSColor(srgbRed: 0.24, green: 0.56, blue: 1.00, alpha: 1)
        case .document: return NSColor(srgbRed: 1.00, green: 0.58, blue: 0.16, alpha: 1)
        case .audio: return NSColor(srgbRed: 1.00, green: 0.31, blue: 0.52, alpha: 1)
        case .video: return NSColor(srgbRed: 0.62, green: 0.42, blue: 1.00, alpha: 1)
        case .data: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.49, alpha: 1)
        }
    }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WheelView: NSView {
    enum Phase {
        case choosing
        case working(String)
        case done(String)
        case failed(String)
        case nothing(String)
    }

    let fileURL: URL
    let groups: [Group]
    let geometry: WheelGeometry
    let icon: NSImage
    var center = CGPoint.zero
    var phase = Phase.choosing { didSet { needsDisplay = true } }
    var open: Int?
    var hover: WheelGeometry.Target?
    var onPick: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    /// While converting, the window shrinks to just the centre disc, so there's no backdrop to dim.
    var compact = false { didSet { needsDisplay = true } }

    private var appear: CGFloat = 0
    private var fanOut: CGFloat = 0
    private var spin: CGFloat = 90
    private var timer: Timer?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(frame: NSRect, file: URL, groups: [Group]) {
        self.fileURL = file
        self.groups = groups
        self.geometry = WheelGeometry(groupCount: groups.count)
        self.icon = NSWorkspace.shared.icon(forFile: file.path)
        super.init(frame: frame)
        if groups.isEmpty {
            phase = .nothing(Formats.deadEndMessage(for: file))
        } else if groups.count == 1 {
            open = 0 // nothing to choose between, so go straight to the formats
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        if reduceMotion { appear = 1; fanOut = 1 } else { animate() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// For screenshots and tests: everything fully open, no animation.
    func settle(open group: Int?, hover target: WheelGeometry.Target?) {
        timer?.invalidate(); timer = nil
        appear = 1; fanOut = 1
        if let group = group { open = group }
        hover = target
        needsDisplay = true
    }

    // MARK: Animation

    func animate() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        var busy = false
        if appear < 1 { appear = min(1, appear + 1.0 / 9); busy = true }
        if open != nil, fanOut < 1 { fanOut = min(1, fanOut + 1.0 / 8); busy = true }
        if case .working = phase { spin -= 9; busy = true }
        needsDisplay = true
        if !busy { timer?.invalidate(); timer = nil }
    }

    private func eased(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

    // MARK: Input

    private func target(_ event: NSEvent) -> WheelGeometry.Target? {
        let p = convert(event.locationInWindow, from: nil)
        let formats = open.map { groups[$0].formats.count } ?? 0
        return geometry.target(at: CGPoint(x: p.x - center.x, y: p.y - center.y), openGroup: open, formats: formats)
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .choosing = phase else { return }
        let now = target(event)
        if now != hover { hover = now; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        switch phase {
        case .working: return
        case .done, .failed, .nothing: onDismiss?(); return
        case .choosing: break
        }
        switch target(event) {
        case .group(let index)?:
            if open != index {
                open = index
                fanOut = reduceMotion ? 1 : 0
                hover = .group(index)
                if reduceMotion { needsDisplay = true } else { animate() }
            }
        case .format(let index)?:
            if let group = open { onPick?(groups[group].formats[index]) }
        case nil:
            onDismiss?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if case .working = phase { return }
        onDismiss?()
    }

    override func keyDown(with event: NSEvent) {
        if case .working = phase { return }
        onDismiss?() // Escape, or any other key: get out of the way
    }

    // MARK: Drawing

    private func segment(_ ctx: CGContext, inner: CGFloat, outer: CGFloat, mid: CGFloat, span: CGFloat) -> CGPath {
        let path = CGMutablePath()
        if span >= 359.9 {
            path.addEllipse(in: CGRect(x: -outer, y: -outer, width: outer * 2, height: outer * 2))
            path.addEllipse(in: CGRect(x: -inner, y: -inner, width: inner * 2, height: inner * 2))
            return path
        }
        let gap: CGFloat = 3.5
        func rad(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
        let go = gap / 2 / outer, gi = gap / 2 / inner // constant-width gap between neighbours
        let start = rad(mid + span / 2), end = rad(mid - span / 2)
        path.addArc(center: .zero, radius: outer, startAngle: start - go, endAngle: end + go, clockwise: true)
        path.addArc(center: .zero, radius: inner, startAngle: end + gi, endAngle: start - gi, clockwise: false)
        path.closeSubpath()
        return path
    }

    private func fill(_ ctx: CGContext, _ path: CGPath, _ color: NSColor) {
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .white,
                      centeredAt p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ]
        let s = NSAttributedString(string: string, attributes: attrs)
        let box = s.size()
        s.draw(at: CGPoint(x: p.x - box.width / 2, y: p.y - box.height / 2))
    }

    private func symbol(_ name: String, size: CGFloat, colors: [NSColor], centeredAt p: CGPoint) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let box = image.size
        image.draw(in: CGRect(x: p.x - box.width / 2, y: p.y - box.height / 2, width: box.width, height: box.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let shown = eased(appear)
        if !compact {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.18 * shown).cgColor)
            ctx.fill(bounds)
        }

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        let scale = 0.86 + 0.14 * shown
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAlpha(shown)
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 18, color: NSColor.black.withAlphaComponent(0.40).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        let base = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 0.97)
        if case .choosing = phase {
            drawGroups(ctx, base)
            drawFormats(ctx, base)
        }
        drawCenter(ctx, base)
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        switch phase {
        case .failed(let message), .nothing(let message): drawNote(message)
        default: break
        }
    }

    private func drawGroups(_ ctx: CGContext, _ base: NSColor) {
        let mid = (WheelGeometry.ring1Inner + WheelGeometry.ring1Outer) / 2
        for (i, group) in groups.enumerated() {
            let path = segment(ctx, inner: WheelGeometry.ring1Inner, outer: WheelGeometry.ring1Outer,
                               mid: geometry.groupAngle(i), span: geometry.groupSpan)
            let isOpen = open == i, isHover = hover == .group(i)
            let color = isOpen ? group.category.color
                : isHover ? group.category.color.withAlphaComponent(0.55) : base
            fill(ctx, path, color)
            let p = WheelGeometry.offset(angle: geometry.groupAngle(i), radius: mid)
            symbol(group.category.symbol, size: 17, colors: [.white], centeredAt: CGPoint(x: p.x, y: p.y + 8))
            text(group.category.title, size: 10.5, weight: .semibold,
                 color: NSColor.white.withAlphaComponent(isOpen || isHover ? 1 : 0.86),
                 centeredAt: CGPoint(x: p.x, y: p.y - 12))
        }
    }

    private func drawFormats(_ ctx: CGContext, _ base: NSColor) {
        guard let group = open else { return }
        let formats = groups[group].formats
        let grow = eased(fanOut)
        let outer = WheelGeometry.ring2Inner + (WheelGeometry.ring2Outer - WheelGeometry.ring2Inner) * grow
        let step = geometry.fan(group: group, formats: formats.count).step
        ctx.saveGState()
        ctx.setAlpha(grow)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for (i, format) in formats.enumerated() {
            let angle = geometry.formatAngle(group: group, formats: formats.count, index: i)
            let path = segment(ctx, inner: WheelGeometry.ring2Inner, outer: outer, mid: angle, span: step)
            let isHover = hover == .format(i)
            fill(ctx, path, isHover ? groups[group].category.color : base)
            let p = WheelGeometry.offset(angle: angle, radius: (WheelGeometry.ring2Inner + outer) / 2)
            text(format.uppercased(), size: 12.5, weight: .bold,
                 color: NSColor.white.withAlphaComponent(isHover ? 1 : 0.92), centeredAt: p)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawCenter(_ ctx: CGContext, _ base: NSColor) {
        let r = WheelGeometry.centerRadius
        ctx.addEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        ctx.setFillColor(base.withAlphaComponent(1).cgColor) // solid: it sits right on top of the real icon
        ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let current = fileURL.pathExtension.uppercased()
        let quiet = NSColor.white.withAlphaComponent(0.62)
        switch phase {
        case .choosing, .nothing:
            icon.draw(in: CGRect(x: -22, y: -12, width: 44, height: 44))
            text(current.isEmpty ? "FILE" : current, size: 11, weight: .bold, color: quiet,
                 centeredAt: CGPoint(x: 0, y: -27))
        case .working(let format):
            icon.draw(in: CGRect(x: -22, y: -12, width: 44, height: 44), from: .zero, operation: .sourceOver, fraction: 0.55)
            text("→ " + format.uppercased(), size: 11, weight: .bold, centeredAt: CGPoint(x: 0, y: -27))
            let a = spin * .pi / 180
            ctx.addArc(center: .zero, radius: r - 4, startAngle: a, endAngle: a - 1.7 * .pi / 2, clockwise: true)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(3)
            ctx.setLineCap(.round)
            ctx.strokePath()
        case .done(let format):
            symbol("checkmark.circle.fill", size: 34,
                   colors: [.white, NSColor(srgbRed: 0.20, green: 0.78, blue: 0.42, alpha: 1)], centeredAt: CGPoint(x: 0, y: 8))
            text(format.uppercased(), size: 11, weight: .bold, centeredAt: CGPoint(x: 0, y: -27))
        case .failed:
            symbol("exclamationmark.triangle.fill", size: 30,
                   colors: [NSColor(srgbRed: 0.15, green: 0.12, blue: 0.05, alpha: 1), NSColor(srgbRed: 1, green: 0.78, blue: 0.20, alpha: 1)],
                   centeredAt: CGPoint(x: 0, y: 8))
            text("Not converted", size: 10, weight: .semibold, color: quiet, centeredAt: CGPoint(x: 0, y: -27))
        }
    }

    /// A short message under the wheel, for errors and files that can't be converted.
    private func drawNote(_ message: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let s = NSAttributedString(string: message, attributes: attrs)
        let box = s.boundingRect(with: CGSize(width: 290, height: 400), options: [.usesLineFragmentOrigin])
        let w = ceil(box.width) + 28, h = ceil(box.height) + 18
        let rect = CGRect(x: center.x - w / 2, y: center.y - WheelGeometry.centerRadius - 14 - h, width: w, height: h)
        let pill = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 0.94).setFill()
        pill.fill()
        s.draw(with: rect.insetBy(dx: 14, dy: 9), options: [.usesLineFragmentOrigin])
    }
}

/// Puts the wheel on screen around a file and runs the conversion the user picks.
final class WheelController {
    static let shared = WheelController()

    private var panel: WheelPanel?
    private(set) var view: WheelView?
    private var outsideClicks: Any?
    private var fullFrame = NSRect.zero
    private var fullCenter = CGPoint.zero

    var isVisible: Bool { panel != nil }
    /// Tests hook in here to learn how a conversion ended.
    var onFinished: ((Result<URL, Error>) -> Void)?

    /// Which display the wheel goes on and where its centre lands (AppKit coordinates, origin bottom-left).
    /// `point` and the hit's frame use the pointer's coordinates: origin at the top-left of the main display.
    static func placement(for hit: FileHit, at point: CGPoint) -> (screen: NSScreen, anchor: CGPoint)? {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        func cocoa(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: mainHeight - p.y) }

        // Wrap the wheel around the icon itself when there is one; otherwise around the pointer.
        var anchor = cocoa(point)
        if let frame = hit.frame, frame.width <= 160, frame.height <= 160 {
            anchor = cocoa(CGPoint(x: frame.midX, y: frame.midY))
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main else { return nil }
        // Keep the whole wheel on screen and clear of the menu bar and Dock.
        let usable = screen.visibleFrame
        let margin = WheelGeometry.extent
        if usable.width > margin * 2 { anchor.x = min(max(anchor.x, usable.minX + margin), usable.maxX - margin) }
        if usable.height > margin * 2 { anchor.y = min(max(anchor.y, usable.minY + margin), usable.maxY - margin) }
        return (screen, anchor)
    }

    func show(_ hit: FileHit, at point: CGPoint) {
        dismiss()
        guard let (screen, anchor) = WheelController.placement(for: hit, at: point) else { return }
        let bounds = screen.frame

        let panel = WheelPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true

        let view = WheelView(frame: NSRect(origin: .zero, size: bounds.size), file: hit.url,
                             groups: Formats.groups(for: hit.url))
        view.center = CGPoint(x: anchor.x - bounds.minX, y: anchor.y - bounds.minY)
        fullFrame = bounds
        fullCenter = view.center
        view.onDismiss = { [weak self] in self?.dismiss() }
        view.onPick = { [weak self] format in self?.pick(format) }
        panel.contentView = view
        panel.setFrame(bounds, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        self.panel = panel
        self.view = view

        // A click on another display should close the wheel too.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if case .working = self?.view?.phase { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        if let monitor = outsideClicks { NSEvent.removeMonitor(monitor); outsideClicks = nil }
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    /// While a conversion runs, the full-screen wheel gets out of the way: the window shrinks to the
    /// centre disc, lets clicks through and drops below system dialogs. macOS may be asking "allow
    /// Morph to access your Desktop folder?" at this very moment, and that has to stay clickable.
    private func setCompact(_ on: Bool) {
        guard let panel = panel, let view = view else { return }
        view.compact = on
        panel.ignoresMouseEvents = on
        panel.level = on ? .floating : .popUpMenu
        if on {
            let side = (WheelGeometry.centerRadius + 26) * 2
            let origin = CGPoint(x: fullFrame.minX + fullCenter.x - side / 2, y: fullFrame.minY + fullCenter.y - side / 2)
            panel.setFrame(NSRect(origin: origin, size: CGSize(width: side, height: side)), display: false)
            view.frame = NSRect(x: 0, y: 0, width: side, height: side)
            view.center = CGPoint(x: side / 2, y: side / 2)
        } else {
            panel.setFrame(fullFrame, display: false)
            view.frame = NSRect(origin: .zero, size: fullFrame.size)
            view.center = fullCenter
        }
        view.needsDisplay = true
    }

    func pick(_ format: String) {
        guard let view = view else { return }
        view.phase = .working(format)
        setCompact(true)
        view.animate()
        let source = view.fileURL

        let finish: (Result<URL, Error>) -> Void = { [weak self, weak view] result in
            guard let self = self else { return }
            if let view = view, self.view === view {
                switch result {
                case .success:
                    view.phase = .done(format)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak view] in
                        if let view = view, self?.view === view { self?.dismiss() }
                    }
                case .failure(let error):
                    self.setCompact(false) // back to full size: the explanation needs room, and a click dismisses it
                    view.phase = .failed(error.localizedDescription)
                }
            }
            self.onFinished?(result)
        }

        if Converter.needsMainThread(from: source.pathExtension) {
            // Give the "working" state one frame on screen before the main thread gets busy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                finish(Result { try Pipeline.convertInPlace(source, to: format) })
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try Pipeline.convertInPlace(source, to: format) }
                DispatchQueue.main.async { finish(result) }
            }
        }
    }
}
