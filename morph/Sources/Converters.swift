import AVFoundation
import Cocoa
import ImageIO
import PDFKit

struct ConvertError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Turns one file into another format, writing the result to `out`. Never touches the original.
enum Converter {
    /// Text import/export and PDF layout go through AppKit, which wants the main thread.
    static func needsMainThread(from srcExt: String) -> Bool {
        let kind = Formats.kind(srcExt)
        return kind == .doc || kind == .pdf
    }

    static func convert(_ src: URL, to dst: String, out: URL) throws {
        let ext = Formats.canonical(src.pathExtension)
        let toImage = Formats.imageUTIs[dst] != nil
        switch Formats.kind(ext) {
        case .image, .gif:
            if dst == "pdf" {
                try imageToPDF(src, out)
            } else if ext == "gif", dst == "mp4" || dst == "mov" {
                try gifToVideo(src, dst, out)
            } else {
                try imageToImage(src, dst, out)
            }
        case .pdf:
            if toImage { try pdfToImage(src, dst, out) } else { try pdfToDoc(src, dst, out) }
        case .doc:
            if dst == "md" {
                try docToMarkdown(src, out)
            } else if dst == "pdf" {
                try docToPDF(src, out)
            } else if toImage {
                let pdf = out.deletingPathExtension().appendingPathExtension("pdf")
                try docToPDF(src, pdf)
                try pdfToImage(pdf, dst, out)
                try? FileManager.default.removeItem(at: pdf)
            } else {
                try writeDoc(loadDoc(src), dst, out)
            }
        case .audio:
            try audio(src, dst, out)
        case .video:
            try video(src, dst, out)
        case .table, .json, .plist:
            if dst == "xlsx" || dst == "pdf" { try office(src, dst, out) } else { try data(src, dst, out) }
        case .sheet, .slides:
            try office(src, dst, out)
        case .unknown:
            throw ConvertError(Formats.deadEndMessage(for: src))
        }
    }

    // MARK: Images

    static func imageToImage(_ src: URL, _ dst: String, _ out: URL) throws {
        guard let uti = Formats.imageUTIs[dst] else { throw ConvertError("Unknown image format .\(dst)") }
        if !Formats.nativeImageWriters.contains(dst) {
            guard let ffmpeg = Tools.ffmpeg else { throw ConvertError("This Mac can't write .\(dst) images.") }
            try run(ffmpeg, ["-y", "-i", src.path, "-frames:v", "1", out.path])
            return
        }
        var (image, props) = try loadImage(src)
        // Formats without transparency would otherwise turn see-through areas black.
        if dst == "jpg" || dst == "bmp" || dst == "gif" && image.bitsPerComponent > 8 { image = flatten(image) }
        props[kCGImageDestinationLossyCompressionQuality] = 0.9
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) else {
            throw ConvertError("Couldn't start writing the .\(dst) file.")
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            // Some source metadata can't be carried into every format; try again without it.
            guard let retry = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) else {
                throw ConvertError("Couldn't write the .\(dst) file.")
            }
            let plain = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
            CGImageDestinationAddImage(retry, flatten(image, keepAlpha: dst != "jpg" && dst != "bmp"), plain)
            guard CGImageDestinationFinalize(retry) else { throw ConvertError("Couldn't write the .\(dst) file.") }
        }
    }

    /// First frame plus the metadata worth keeping (orientation, EXIF, colour profile name).
    static func loadImage(_ src: URL) throws -> (CGImage, [CFString: Any]) {
        if let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let all = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            var keep: [CFString: Any] = [:]
            for key in [kCGImagePropertyOrientation, kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyTIFFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                if let value = all[key] { keep[key] = value }
            }
            return (image, keep)
        }
        // Vector art (SVG) and anything else AppKit understands but ImageIO doesn't.
        if let ns = NSImage(contentsOf: src) {
            var rect = CGRect(origin: .zero, size: ns.size)
            if rect.width > 0, rect.width < 1024 {
                let scale = 1024 / rect.width
                rect.size = CGSize(width: 1024, height: (rect.height * scale).rounded())
            }
            if let image = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return (image, [:]) }
        }
        throw ConvertError("Couldn't read this image.")
    }

    static func flatten(_ image: CGImage, keepAlpha: Bool = false) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let alpha = keepAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue) else { return image }
        if !keepAlpha {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
        }
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// The picture turned the right way up, for formats that have no orientation tag.
    static func uprightImage(_ src: URL) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 4096
            let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 4096
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        return try loadImage(src).0
    }

    static func imageToPDF(_ src: URL, _ out: URL) throws {
        let image = try uprightImage(src)
        // One point per pixel, scaled down to fit a Letter page so it prints sensibly.
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let fit = min(1, 612 / w, 792 / h)
        let page = NSSize(width: w * fit, height: h * fit)
        let flat = image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst
            ? image : flatten(image)
        if let pdfPage = PDFPage(image: NSImage(cgImage: flat, size: page)) {
            let doc = PDFDocument()
            doc.insert(pdfPage, at: 0)
            if doc.write(to: out) { return }
        }
        var box = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw ConvertError("Couldn't create the PDF.") }
        ctx.beginPDFPage(nil)
        ctx.draw(flat, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: PDF

    /// Every page, stacked top to bottom in one picture.
    static func pdfToImage(_ src: URL, _ dst: String, _ out: URL) throws {
        guard let doc = PDFDocument(url: src), doc.pageCount > 0 else { throw ConvertError("Couldn't open this PDF.") }
        if doc.isLocked { throw ConvertError("This PDF is password-protected.") }
        var sizes: [CGSize] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let b = page.bounds(for: .cropBox)
            sizes.append(page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width))
        }
        let width = sizes.map { $0.width }.max() ?? 612
        let height = sizes.reduce(0) { $0 + $1.height }
        let scale = min(2, 24000 / max(height, 1), 8000 / max(width, 1))
        let pxW = Int((width * scale).rounded()), pxH = Int((height * scale).rounded())
        guard pxW > 0, pxH > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConvertError("This PDF is too large to turn into one picture.")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.interpolationQuality = .high
        var top = CGFloat(pxH)
        var n = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let size = CGSize(width: (sizes[n].width * scale).rounded(), height: (sizes[n].height * scale).rounded())
            n += 1
            top -= size.height
            let thumb = page.thumbnail(of: size, for: .cropBox)
            var rect = CGRect(origin: .zero, size: size)
            if let cg = thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                ctx.draw(cg, in: CGRect(x: 0, y: top, width: size.width, height: size.height))
            }
        }
        guard let image = ctx.makeImage(), let uti = Formats.imageUTIs[dst],
              let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) else {
            throw ConvertError("Couldn't write the .\(dst) file.")
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9,
                                      kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError("Couldn't write the .\(dst) file.") }
    }

    /// Pulls the words out of a PDF. Layout and pictures don't come along.
    static func pdfToDoc(_ src: URL, _ dst: String, _ out: URL) throws {
        guard let doc = PDFDocument(url: src) else { throw ConvertError("Couldn't open this PDF.") }
        if doc.isLocked { throw ConvertError("This PDF is password-protected.") }
        let text = doc.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConvertError("This PDF has no selectable text (it looks like a scan), so there's nothing to turn into a document.")
        }
        try writeDoc(plain(text), dst, out)
    }

    // MARK: Documents

    static func plain(_ text: String) -> NSAttributedString {
        let font = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    static func readText(_ src: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let s = try? String(contentsOf: src, usedEncoding: &encoding) { return s }
        return String(decoding: try Data(contentsOf: src), as: UTF8.self)
    }

    static func loadDoc(_ src: URL) throws -> NSAttributedString {
        let ext = Formats.canonical(src.pathExtension)
        if ext == "txt" { return plain(try readText(src)) }
        if ext == "md" {
            let html = Data(MiniMarkdown.html(try readText(src)).utf8)
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
            return try NSAttributedString(data: html, options: options, documentAttributes: nil)
        }
        do {
            return try NSAttributedString(url: src, options: [:], documentAttributes: nil)
        } catch {
            throw ConvertError("Couldn't read this document.")
        }
    }

    static func writeDoc(_ text: NSAttributedString, _ dst: String, _ out: URL) throws {
        if dst == "txt" {
            try text.string.write(to: out, atomically: true, encoding: .utf8)
            return
        }
        if dst == "pdf" {
            try renderPDF(text, out)
            return
        }
        let types: [String: NSAttributedString.DocumentType] = [
            "docx": .officeOpenXML, "rtf": .rtf, "odt": .openDocument, "html": .html, "doc": .docFormat,
        ]
        guard let type = types[dst] else { throw ConvertError("Morph can't write .\(dst) documents.") }
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if dst == "html" { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs)
        try data.write(to: out)
    }

    static func docToPDF(_ src: URL, _ out: URL) throws {
        let ext = Formats.canonical(src.pathExtension)
        // LibreOffice keeps Word layout (tables, images, headers) far better than the built-in importer.
        if Tools.soffice != nil, ["doc", "docx", "odt"].contains(ext), (try? office(src, "pdf", out)) != nil { return }
        try renderPDF(loadDoc(src), out)
    }

    /// Lays text out on Letter pages with one-inch margins.
    static func renderPDF(_ text: NSAttributedString, _ out: URL) throws {
        if Thread.isMainThread, printPDF(text, out) { return }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw ConvertError("Couldn't create the PDF.") }
        let setter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let path = CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil)
        var location = 0
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            location += visible.length
        } while location < text.length
        ctx.closePDF()
    }

    /// The system print pipeline: handles tables, lists and inline pictures properly.
    static func printPDF(_ text: NSAttributedString, _ out: URL) -> Bool {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 72; info.bottomMargin = 72; info.leftMargin = 72; info.rightMargin = 72
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary().setObject(out, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 144, height: 792 - 144))
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { return false }
        return fileSize(out) > 0
    }

    static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func docToMarkdown(_ src: URL, _ out: URL) throws {
        guard let pandoc = Tools.pandoc else { throw ConvertError("Install pandoc to write Markdown.") }
        let html = out.deletingPathExtension().appendingPathExtension("tmp.html")
        try writeDoc(loadDoc(src), "html", html)
        defer { try? FileManager.default.removeItem(at: html) }
        try run(pandoc, ["-f", "html", "-t", "gfm", "--wrap=none", "-o", out.path, html.path])
    }

    // MARK: Audio and video

    static func audio(_ src: URL, _ dst: String, _ out: URL) throws {
        let ext = Formats.canonical(src.pathExtension)
        let native: [String: [String]] = [
            "m4a": ["-f", "m4af", "-d", "aac"], "wav": ["-f", "WAVE", "-d", "LEI16"],
            "aiff": ["-f", "AIFF", "-d", "BEI16"], "flac": ["-f", "flac", "-d", "flac"],
        ]
        if let args = native[dst], Formats.nativeAudioIn.contains(ext) {
            try run("/usr/bin/afconvert", args + [src.path, out.path])
        } else if let ffmpeg = Tools.ffmpeg {
            try run(ffmpeg, ["-y", "-i", src.path, "-vn", out.path])
        } else {
            throw ConvertError("Install ffmpeg (brew install ffmpeg) to make .\(dst) files.")
        }
    }

    static func video(_ src: URL, _ dst: String, _ out: URL) throws {
        let ext = Formats.canonical(src.pathExtension)
        let native = Formats.nativeVideoIn.contains(ext)
        switch dst {
        case "gif" where native:
            try videoToGIF(src, out)
        case "m4a" where native:
            try export(src, out, .m4a, presets: [AVAssetExportPresetAppleM4A])
        case "wav" where native:
            let m4a = out.deletingPathExtension().appendingPathExtension("tmp.m4a")
            try export(src, m4a, .m4a, presets: [AVAssetExportPresetAppleM4A])
            defer { try? FileManager.default.removeItem(at: m4a) }
            try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16", m4a.path, out.path])
        case "mp4" where native, "mov" where native, "m4v" where native:
            let type: AVFileType = dst == "mp4" ? .mp4 : dst == "mov" ? .mov : .m4v
            // Passthrough repackages without re-encoding: instant and lossless when the codecs allow it.
            try export(src, out, type, presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality])
        default:
            guard let ffmpeg = Tools.ffmpeg else {
                throw ConvertError("Install ffmpeg (brew install ffmpeg) to make .\(dst) files.")
            }
            let audioOnly = ["mp3", "m4a", "wav"].contains(dst)
            try run(ffmpeg, ["-y", "-i", src.path] + (audioOnly ? ["-vn"] : []) + [out.path])
        }
    }

    static func export(_ src: URL, _ out: URL, _ type: AVFileType, presets: [String]) throws {
        let asset = AVURLAsset(url: src)
        if presets == [AVAssetExportPresetAppleM4A], asset.tracks(withMediaType: .audio).isEmpty {
            throw ConvertError("This video has no sound to extract.")
        }
        var failure = "Couldn't export this video."
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset),
                  session.supportedFileTypes.contains(type) else { continue }
            try? FileManager.default.removeItem(at: out)
            session.outputURL = out
            session.outputFileType = type
            let done = DispatchSemaphore(value: 0)
            session.exportAsynchronously { done.signal() }
            done.wait()
            if session.status == .completed { return }
            if let error = session.error { failure = error.localizedDescription }
        }
        throw ConvertError(failure)
    }

    static func videoToGIF(_ src: URL, _ out: URL) throws {
        let asset = AVURLAsset(url: src)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0, !asset.tracks(withMediaType: .video).isEmpty else {
            throw ConvertError("Couldn't read this video.")
        }
        // Keep GIFs a sane size: at most 300 frames, 480 points on the long side.
        let fps = min(12, 300 / seconds)
        let count = max(1, Int(seconds * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw ConvertError("Couldn't create the GIF.")
        }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, loop)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var added = 0
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            CGImageDestinationAddImage(dest, frame, delay)
            added += 1
        }
        guard added > 0, CGImageDestinationFinalize(dest) else { throw ConvertError("Couldn't create the GIF.") }
    }

    static func gifToVideo(_ src: URL, _ dst: String, _ out: URL) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConvertError("Couldn't read this GIF.")
        }
        let count = CGImageSourceGetCount(source)
        // H.264 wants even dimensions.
        let width = max(2, first.width / 2 * 2), height = max(2, first.height / 2 * 2)
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: dst == "mov" ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw ConvertError("Couldn't set up the video encoder.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ConvertError(writer.error?.localizedDescription ?? "Couldn't start the video encoder.")
        }
        writer.startSession(atSourceTime: .zero)

        var clock = 0.0
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let props = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]) ?? [:]
            let gif = (props[kCGImagePropertyGIFDictionary] as? [CFString: Any]) ?? [:]
            var delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            if delay < 0.02 { delay = 0.1 }

            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 5000 { usleep(2000); waited += 1 }
            var buffer: CVPixelBuffer?
            let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                         kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs, &buffer)
            guard let pixels = buffer else { throw ConvertError("Ran out of memory building the video.") }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            if !adaptor.append(pixels, withPresentationTime: CMTime(seconds: clock, preferredTimescale: 600)) {
                throw ConvertError(writer.error?.localizedDescription ?? "The video encoder stopped.")
            }
            clock += delay
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: clock, preferredTimescale: 600))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw ConvertError(writer.error?.localizedDescription ?? "Couldn't finish the video.")
        }
    }

    // MARK: Data

    static func data(_ src: URL, _ dst: String, _ out: URL) throws {
        let ext = Formats.canonical(src.pathExtension)
        switch (ext, dst) {
        case ("csv", "tsv"), ("tsv", "csv"):
            let rows = parseDelimited(try readText(src), ext == "tsv" ? "\t" : ",")
            try writeDelimited(rows, dst == "tsv" ? "\t" : ",").write(to: out, atomically: true, encoding: .utf8)
        case ("csv", "json"), ("tsv", "json"):
            let rows = parseDelimited(try readText(src), ext == "tsv" ? "\t" : ",")
            try rowsToJSON(rows).write(to: out, atomically: true, encoding: .utf8)
        case ("json", "csv"):
            let text = try readText(src)
            try writeDelimited(try jsonToRows(text), ",").write(to: out, atomically: true, encoding: .utf8)
        case ("json", "plist"):
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: src), options: [.fragmentsAllowed])
            let plist = try PropertyListSerialization.data(fromPropertyList: plistSafe(object), format: .xml, options: 0)
            try plist.write(to: out)
        case ("plist", "json"):
            let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: src), options: [], format: nil)
            let json = try JSONSerialization.data(withJSONObject: jsonSafe(object),
                                                  options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            try json.write(to: out)
        default:
            throw ConvertError("Morph can't turn .\(ext) into .\(dst).")
        }
    }

    static func parseDelimited(_ text: String, _ delimiter: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"", field.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func writeDelimited(_ rows: [[String]], _ delimiter: String) -> String {
        rows.map { row in
            row.map { field -> String in
                let risky = field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r")
                return risky ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: delimiter)
        }.joined(separator: "\n") + "\n"
    }

    static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// First row becomes the keys; columns stay in their original order.
    static func rowsToJSON(_ rows: [[String]]) throws -> String {
        guard let header = rows.first, !header.isEmpty else { throw ConvertError("This table is empty.") }
        let numeric = try NSRegularExpression(pattern: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$")
        var objects: [String] = []
        for row in rows.dropFirst() where !(row.count == 1 && row[0].isEmpty) {
            var pairs: [String] = []
            for (i, key) in header.enumerated() {
                let value = i < row.count ? row[i] : ""
                let isNumber = numeric.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
                pairs.append("    " + jsonString(key) + ": " + (isNumber ? value : jsonString(value)))
            }
            objects.append("  {\n" + pairs.joined(separator: ",\n") + "\n  }")
        }
        return "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }

    static func jsonToRows(_ text: String) throws -> [[String]] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [])
        func cell(_ value: Any) -> String {
            if value is NSNull { return "" }
            if let s = value as? String { return s }
            if let n = value as? NSNumber {
                return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
            }
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        if let records = object as? [[String: Any]], !records.isEmpty {
            var keys: [String] = []
            for record in records { for key in record.keys where !keys.contains(key) { keys.append(key) } }
            // JSON objects lose their key order when parsed; recover it from where each key first appears.
            func firstSeen(_ key: String) -> Int {
                text.range(of: jsonString(key)).map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? Int.max
            }
            let order = Dictionary(uniqueKeysWithValues: keys.map { ($0, firstSeen($0)) })
            keys.sort { (order[$0] ?? 0, $0) < (order[$1] ?? 0, $1) }
            return [keys] + records.map { record in keys.map { record[$0].map(cell) ?? "" } }
        }
        if let rows = object as? [[Any]], !rows.isEmpty { return rows.map { $0.map(cell) } }
        throw ConvertError("Only a JSON list of records (or a list of rows) can become a spreadsheet.")
    }

    /// Property lists have no null: drop empty keys, blank out empty list slots.
    static func plistSafe(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, v) in dict where !(v is NSNull) { out[key] = plistSafe(v) }
            return out
        }
        if let list = value as? [Any] { return list.map { $0 is NSNull ? "" : plistSafe($0) } }
        return value
    }

    /// JSON has no dates or raw bytes: write them as ISO 8601 and Base64.
    static func jsonSafe(_ value: Any) -> Any {
        if let dict = value as? [String: Any] { return dict.mapValues(jsonSafe) }
        if let list = value as? [Any] { return list.map(jsonSafe) }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if let data = value as? Data { return data.base64EncodedString() }
        return value
    }

    // MARK: Helpers

    static func office(_ src: URL, _ dst: String, _ out: URL) throws {
        guard let soffice = Tools.soffice else { throw ConvertError("Install LibreOffice to convert this file.") }
        let dir = out.deletingLastPathComponent()
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("morph-libreoffice-profile")
        try run(soffice, ["-env:UserInstallation=" + profile.absoluteString, "--headless",
                          "--convert-to", dst, "--outdir", dir.path, src.path])
        let produced = dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + "." + dst)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw ConvertError("LibreOffice couldn't convert this file.")
        }
        if produced.path != out.path {
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: produced, to: out)
        }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let tail = output.split(separator: "\n").suffix(2).joined(separator: " ")
            let name = URL(fileURLWithPath: path).lastPathComponent
            throw ConvertError(tail.isEmpty ? "\(name) failed." : "\(name): \(tail)")
        }
        return output
    }
}
