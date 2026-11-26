import AVFoundation
import ApplicationServices
import Cocoa

/// Command-line entry points: a plain converter, plus the hooks the automated tests drive.
///
///   Morph --convert <file> <format>     convert a file in place, exactly as the wheel would
///   Morph --targets <file>              list what a file can become
///   Morph --probe <x> <y>               which Finder file is at this screen point?
///   Morph --selftest                    run every conversion Morph knows on generated samples
enum Debug {
    private static var guiMode: [String] = []

    /// Returns an exit code if the arguments were a command-line job, nil to start the app.
    static func runCommandLine(_ args: [String]) -> Int32? {
        guard let mode = args.first, mode.hasPrefix("--") else { return nil }
        let rest = Array(args.dropFirst())
        func number(_ i: Int) -> CGFloat { i < rest.count ? CGFloat(Double(rest[i]) ?? 0) : 0 }
        switch mode {
        case "--convert" where rest.count == 2:
            _ = NSApplication.shared
            do {
                let out = try Pipeline.convertInPlace(URL(fileURLWithPath: rest[0]), to: Formats.canonical(rest[1]))
                print(out.path)
                return 0
            } catch {
                print("error: \(error.localizedDescription)")
                return 1
            }
        case "--targets" where rest.count == 1:
            let url = URL(fileURLWithPath: rest[0])
            let groups = Formats.groups(for: url)
            if groups.isEmpty { print(Formats.deadEndMessage(for: url)) }
            for group in groups { print("\(group.category.title): \(group.formats.joined(separator: " "))") }
            return 0
        case "--icon" where rest.count == 2:
            guard let png = Artwork.appIcon(pixels: Int(rest[1]) ?? 512) else { return 1 }
            return (try? png.write(to: URL(fileURLWithPath: rest[0]))) == nil ? 1 : 0
        case "--selftest":
            return selfTest()
        case "--probe" where rest.count == 2:
            print("trusted: \(AXIsProcessTrusted())")
            if let hit = FinderProbe.file(at: CGPoint(x: number(0), y: number(1))) {
                print("HIT \(hit.url.path) frame=\(hit.frame.map { "\($0)" } ?? "-")")
            } else {
                print("MISS")
            }
            return 0
        case "--find" where rest.count == 1:
            return find(rest[0])
        case "--dump":
            dump(depth: rest.first.flatMap { Int($0) } ?? 7)
            return 0
        case "--click" where rest.count >= 2:
            click(at: CGPoint(x: number(0), y: number(1)), trigger: rest.contains("trigger"))
            return 0
        case "--move" where rest.count == 2:
            click(at: CGPoint(x: number(0), y: number(1)), trigger: false, press: false)
            return 0
        case "--layout" where rest.count == 5:
            return layout(file: URL(fileURLWithPath: rest[0]), center: CGPoint(x: number(1), y: number(2)),
                          category: rest[3], format: rest[4])
        case "--demo" where !rest.isEmpty:
            guiMode = args
            return nil
        default:
            print("usage: Morph [--convert <file> <format> | --targets <file> | --probe <x> <y> | --selftest]")
            return 2
        }
    }

    /// `--demo <file> [group] [format] [state]`: put the wheel mid-screen, fully open, for screenshots.
    static func runGUIMode() -> Bool {
        guard guiMode.first == "--demo", guiMode.count >= 2 else { return false }
        let file = URL(fileURLWithPath: guiMode[1])
        let group = guiMode.count > 2 ? Int(guiMode[2]) : nil
        let format = guiMode.count > 3 ? Int(guiMode[3]) : nil
        let state = guiMode.count > 4 ? guiMode[4] : ""
        guard let screen = NSScreen.main else { return true }
        let point = CGPoint(x: screen.frame.midX, y: screen.frame.height / 2)
        WheelController.shared.show(FileHit(url: file, frame: nil), at: point)
        guard let view = WheelController.shared.view else { return true }
        let groups = Formats.groups(for: file)
        let open = group.flatMap { $0 >= 0 && $0 < groups.count ? $0 : nil }
        let hover = format.map { WheelGeometry.Target.format($0) } ?? open.map { WheelGeometry.Target.group($0) }
        view.settle(open: open, hover: hover)
        let name = open.flatMap { g in format.flatMap { f in f < groups[g].formats.count ? groups[g].formats[f] : nil } } ?? "jpg"
        switch state {
        case "working": view.phase = .working(name)
        case "done": view.phase = .done(name)
        case "failed": view.phase = .failed("This PDF has no selectable text (it looks like a scan), so there's nothing to turn into a document.")
        default: break
        }
        return true
    }

    // MARK: Finder inspection

    static var finder: AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    static func walk(_ element: AXUIElement, depth: Int, limit: Int, visit: (AXUIElement, Int) -> Void) {
        visit(element, depth)
        guard depth < limit, axString(element, "AXRole") != "AXMenuBar" else { return }
        for child in axChildren(element).prefix(60) { walk(child, depth: depth + 1, limit: limit, visit: visit) }
    }

    static func dump(depth: Int) {
        guard let finder = finder else { print("Finder isn't running"); return }
        walk(finder, depth: 0, limit: depth) { element, level in
            let url = (axValue(element, "AXURL") as? URL).map { ($0 as NSURL).filePathURL?.lastPathComponent ?? "?" } ?? ""
            let line = "\(axString(element, "AXRole")) \(axString(element, "AXSubrole")) title=\(axString(element, "AXTitle")) "
                + "value=\((axValue(element, "AXValue") as? String) ?? "") file=\(url) frame=\(axFrame(element).map { "\($0)" } ?? "-")"
            print(String(repeating: "  ", count: level) + line)
        }
    }

    /// Finds a file's icons and rows in Finder, then checks that pointing at each one resolves back to the file.
    static func find(_ name: String) -> Int32 {
        guard let finder = finder else { print("Finder isn't running"); return 1 }
        print("trusted: \(AXIsProcessTrusted())")
        var frames: [(String, CGRect)] = []
        walk(finder, depth: 0, limit: 12) { element, _ in
            guard let url = FinderProbe.fileURL(element), url.lastPathComponent == name,
                  let frame = axFrame(element), frame.width > 0 else { return }
            frames.append((axString(element, "AXRole"), frame))
        }
        if frames.isEmpty { print("NOTFOUND \(name)"); return 1 }
        var bad = 0
        for (role, frame) in frames {
            print("FOUND \(role) \(frame)")
            print("CENTER \(Int(frame.midX)) \(Int(frame.midY))")
            var points = [("centre", CGPoint(x: frame.midX, y: frame.midY))]
            if frame.width <= 160 { points.append(("name", CGPoint(x: frame.midX, y: frame.maxY + 14))) }
            if frame.width > 160 { points.append(("far right", CGPoint(x: frame.maxX - 30, y: frame.midY))) }
            for (label, point) in points {
                let hit = FinderProbe.file(at: point)
                let ok = hit?.url.lastPathComponent == name
                if !ok { bad += 1 }
                print("  \(ok ? "ok  " : "MISS") \(label) \(point) → \(hit?.url.lastPathComponent ?? "nothing")")
            }
        }
        return bad == 0 ? 0 : 3
    }

    static func click(at point: CGPoint, trigger: Bool, press: Bool = true) {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, pause: useconds_t) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = trigger ? Trigger.current.flags : []
            event?.post(tap: .cghidEventTap)
            usleep(pause)
        }
        post(.mouseMoved, pause: 200_000)
        guard press else { return }
        post(.leftMouseDown, pause: 80_000)
        post(.leftMouseUp, pause: 150_000)
    }

    /// Screen points for a category and one of its formats, for a wheel centred at `center`.
    static func layout(file: URL, center: CGPoint, category: String, format: String) -> Int32 {
        let groups = Formats.groups(for: file)
        guard let g = groups.firstIndex(where: { $0.category.title == category }),
              let f = groups[g].formats.firstIndex(of: format) else { print("no such target"); return 1 }
        let geometry = WheelGeometry(groupCount: groups.count)
        let a = WheelGeometry.offset(angle: geometry.groupAngle(g),
                                     radius: (WheelGeometry.ring1Inner + WheelGeometry.ring1Outer) / 2)
        let b = WheelGeometry.offset(angle: geometry.formatAngle(group: g, formats: groups[g].formats.count, index: f),
                                     radius: (WheelGeometry.ring2Inner + WheelGeometry.ring2Outer) / 2)
        // Screen y runs downward; the wheel's runs upward.
        print("GROUP \(Int(center.x + a.x)) \(Int(center.y - a.y))")
        print("FORMAT \(Int(center.x + b.x)) \(Int(center.y - b.y))")
        return 0
    }

    // MARK: Self-test

    static func inode(_ url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// Does the file start the way a real file of this type starts?
    static func looksLike(_ ext: String, _ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = [UInt8](handle.readData(ofLength: 16))
        func at(_ offset: Int, _ text: String) -> Bool {
            let bytes = Array(text.utf8)
            return head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        switch ext {
        case "png": return at(1, "PNG")
        case "jpg": return head.starts(with: [0xFF, 0xD8])
        case "gif": return at(0, "GIF8")
        case "pdf": return at(0, "%PDF")
        case "bmp": return at(0, "BM")
        case "tiff": return at(0, "II*") || at(0, "MM")
        case "webp": return at(0, "RIFF") && at(8, "WEBP")
        case "heic", "mp4", "m4v", "m4a": return at(4, "ftyp")
        case "mov": return at(4, "ftyp") || at(4, "wide") || at(4, "moov") || at(4, "free")
        case "wav": return at(0, "RIFF")
        case "aiff": return at(0, "FORM")
        case "flac": return at(0, "fLaC")
        case "docx", "odt", "xlsx": return at(0, "PK")
        case "rtf": return at(0, "{\\rtf")
        case "plist": return at(0, "<?xml")
        case "json": return at(0, "[") || at(0, "{")
        default: return !head.isEmpty
        }
    }

    static func makeSeeds(in root: URL) throws -> [URL] {
        let fm = FileManager.default
        let seeds = root.appendingPathComponent("seeds")
        try fm.createDirectory(at: seeds, withIntermediateDirectories: true)
        func path(_ name: String) -> URL { seeds.appendingPathComponent(name) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ConvertError("no colour space") }

        func picture(_ w: Int, _ h: Int, shift: CGFloat) throws -> CGImage {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ConvertError("no context")
            }
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2)) // top half stays transparent
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.4, blue: 0.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: CGFloat(w) * shift, y: CGFloat(h) * 0.3, width: CGFloat(h) * 0.4, height: CGFloat(h) * 0.4))
            guard let image = ctx.makeImage() else { throw ConvertError("no image") }
            return image
        }
        func write(_ images: [CGImage], _ uti: String, _ url: URL, delay: Double? = nil) throws {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, images.count, nil) else {
                throw ConvertError("no destination")
            }
            let props = delay.map { [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: $0]] as CFDictionary }
            for image in images { CGImageDestinationAddImage(dest, image, props) }
            guard CGImageDestinationFinalize(dest) else { throw ConvertError("couldn't write \(url.lastPathComponent)") }
        }

        try write([picture(400, 300, shift: 0.4)], "public.png", path("seed.png"))
        try write(try (0..<8).map { try picture(160, 120, shift: 0.1 + CGFloat($0) * 0.08) }, "com.compuserve.gif",
                  path("seed.gif"), delay: 0.15)

        let prose = (1...60).map { "Line \($0): the quick brown fox jumps over the lazy dog, café, naïve, 日本語." }
        try prose.joined(separator: "\n").write(to: path("seed.txt"), atomically: true, encoding: .utf8)
        try """
        # Morph test

        Some **bold**, some *italic*, some `code`, and a [link](https://example.com).

        - one
        - two

        1. first
        2. second

        > quoted

        ```
        let x = 1 < 2
        ```
        """.write(to: path("seed.md"), atomically: true, encoding: .utf8)
        try "name,city,age\nAda,\"London, UK\",36\nGrace,\"New \"\"York\"\"\",45\n"
            .write(to: path("seed.csv"), atomically: true, encoding: .utf8)
        try "[{\"name\": \"Ada\", \"age\": 36, \"tags\": [\"a\"], \"ok\": true}, {\"name\": \"Grace\", \"city\": null}]"
            .write(to: path("seed.json"), atomically: true, encoding: .utf8)

        // One second of a 440 Hz tone as a 16-bit mono WAV.
        let rate = 44100
        var wav = Data()
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); le32(36 + rate * 2); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        le32(16); le16(1); le16(1); le32(rate); le32(rate * 2); le16(2); le16(16)
        wav.append(contentsOf: Array("data".utf8)); le32(rate * 2)
        for i in 0..<rate {
            let sample = Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 12000)
            withUnsafeBytes(of: sample.littleEndian) { wav.append(contentsOf: $0) }
        }
        try wav.write(to: path("seed.wav"))

        var all = ["seed.txt", "seed.md", "seed.csv", "seed.json", "seed.wav", "seed.gif", "seed.png"].map(path)

        // A movie with both picture and sound, built from the GIF and the tone.
        do {
            let silent = path("silent.mp4"), tone = path("tone.m4a"), movie = path("seed.mov")
            try Converter.gifToVideo(path("seed.gif"), "mp4", silent)
            try Converter.audio(path("seed.wav"), "m4a", tone)
            let video = AVURLAsset(url: silent), sound = AVURLAsset(url: tone)
            let mix = AVMutableComposition()
            guard let v = video.tracks(withMediaType: .video).first, let a = sound.tracks(withMediaType: .audio).first,
                  let vt = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let at = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ConvertError("no tracks")
            }
            let length = CMTimeMinimum(video.duration, sound.duration)
            try vt.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: v, at: .zero)
            try at.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: a, at: .zero)
            guard let session = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetPassthrough) else {
                throw ConvertError("no export session")
            }
            session.outputURL = movie
            session.outputFileType = .mov
            let done = DispatchSemaphore(value: 0)
            session.exportAsynchronously { done.signal() }
            done.wait()
            guard session.status == .completed else { throw session.error ?? ConvertError("export failed") }
            try? fm.removeItem(at: silent)
            try? fm.removeItem(at: tone)
            all.insert(movie, at: 0)
        } catch {
            print("warning: couldn't build a movie with sound (\(error.localizedDescription)); video tests will be thinner")
        }
        return all
    }

    /// Starts from generated samples and converts each one into everything it can become, then does
    /// the same with every new kind of file that produces, until every route has been exercised.
    static func selfTest() -> Int32 {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("morph-selftest-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        var queue: [URL]
        do { queue = try makeSeeds(in: root) } catch {
            print("FAIL couldn't make sample files: \(error.localizedDescription)")
            return 1
        }
        print("optional tools: ffmpeg=\(Tools.ffmpeg ?? "no") pandoc=\(Tools.pandoc ?? "no") libreoffice=\(Tools.soffice ?? "no")")
        print("image writers: \(Formats.nativeImageWriters.sorted().joined(separator: " "))")

        var seen = Set<String>(), passed = 0, failed = 0
        while !queue.isEmpty {
            let sample = queue.removeFirst()
            let ext = Formats.canonical(sample.pathExtension)
            if !seen.insert(ext).inserted { continue }
            for group in Formats.groups(for: sample) {
                for dst in group.formats {
                    let dir = root.appendingPathComponent("run-\(ext)-\(dst)")
                    let copy = dir.appendingPathComponent("My File." + sample.pathExtension)
                    let label = "\(ext) → \(dst)".padding(toLength: 14, withPad: " ", startingAt: 0)
                    do {
                        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                        try fm.copyItem(at: sample, to: copy)
                        let before = inode(copy), started = Date()
                        let out = try Pipeline.convertInPlace(copy, to: dst)
                        var problems: [String] = []
                        if out.lastPathComponent != "My File.\(dst)" { problems.append("named \(out.lastPathComponent)") }
                        if fm.fileExists(atPath: copy.path) { problems.append("original name still there") }
                        if inode(out) != before { problems.append("not the same file on disk") }
                        if !looksLike(dst, out) { problems.append("contents don't look like .\(dst)") }
                        if (try? fm.contentsOfDirectory(atPath: dir.path).count) != 1 { problems.append("left extra files") }
                        if problems.isEmpty {
                            let ms = Int(Date().timeIntervalSince(started) * 1000)
                            print("ok   \(label) \(Converter.fileSize(out)) bytes, \(ms) ms")
                            passed += 1
                            queue.append(out)
                        } else {
                            print("FAIL \(label) \(problems.joined(separator: "; "))")
                            failed += 1
                        }
                    } catch {
                        print("FAIL \(label) \(error.localizedDescription)")
                        failed += 1
                    }
                }
            }
        }
        print("\(passed) conversions passed, \(failed) failed, \(seen.count) source formats covered")
        return failed == 0 ? 0 : 1
    }
}
