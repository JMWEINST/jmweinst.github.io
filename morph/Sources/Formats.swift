import Foundation
import ImageIO

/// The first ring of the wheel.
enum Category: Int {
    case image, document, audio, video, data

    var title: String {
        switch self {
        case .image: return "Image"
        case .document: return "Document"
        case .audio: return "Audio"
        case .video: return "Video"
        case .data: return "Data"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .document: return "doc.text"
        case .audio: return "waveform"
        case .video: return "film"
        case .data: return "tablecells"
        }
    }
}

/// One category and the formats inside it that this particular file can become.
struct Group {
    let category: Category
    let formats: [String]
}

enum Kind {
    case image, gif, pdf, doc, audio, video, table, json, plist, sheet, slides, unknown
}

/// Optional helpers. Morph works without any of them; each one unlocks a few more formats.
enum Tools {
    static func find(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
    static let ffmpeg = find("ffmpeg")
    static let pandoc = find("pandoc")
    static let soffice: String? = {
        let app = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        return FileManager.default.isExecutableFile(atPath: app) ? app : find("soffice")
    }()
}

enum Formats {
    static let aliases = [
        "jpeg": "jpg", "jpe": "jpg", "tif": "tiff", "heif": "heic", "htm": "html",
        "markdown": "md", "aif": "aiff", "text": "txt",
    ]

    static func canonical(_ ext: String) -> String {
        let e = ext.lowercased()
        return aliases[e] ?? e
    }

    static let imageUTIs = [
        "png": "public.png", "jpg": "public.jpeg", "heic": "public.heic", "tiff": "public.tiff",
        "gif": "com.compuserve.gif", "bmp": "com.microsoft.bmp", "webp": "org.webmproject.webp",
    ]

    /// What this Mac's own image encoder can write (HEIC and WebP vary by macOS version).
    static let nativeImageWriters: Set<String> = {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return Set(imageUTIs.filter { ids.contains($0.value) }.keys)
    }()

    static func canWriteImage(_ ext: String) -> Bool {
        nativeImageWriters.contains(ext) || (ext == "webp" && Tools.ffmpeg != nil)
    }

    static let imagesIn: Set<String> = [
        "png", "jpg", "heic", "tiff", "bmp", "webp", "avif", "jp2", "psd", "ico", "tga", "svg",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]
    static let docsIn: Set<String> = ["txt", "rtf", "doc", "docx", "odt", "html", "webarchive", "md"]
    static let nativeAudioIn: Set<String> = ["mp3", "wav", "aiff", "m4a", "aac", "flac", "caf", "m4b"]
    static let ffmpegAudioIn: Set<String> = ["ogg", "opus", "wma", "oga"]
    static let nativeVideoIn: Set<String> = ["mov", "mp4", "m4v"]
    static let ffmpegVideoIn: Set<String> = ["mkv", "avi", "webm", "flv", "wmv", "mpg", "mpeg"]
    static let sheetsIn: Set<String> = ["xlsx", "xls", "ods"]
    static let slidesIn: Set<String> = ["pptx", "ppt", "odp"]

    static func kind(_ rawExt: String) -> Kind {
        let ext = canonical(rawExt)
        if ext == "gif" { return .gif }
        if ext == "pdf" { return .pdf }
        if imagesIn.contains(ext) { return .image }
        if docsIn.contains(ext) { return .doc }
        if nativeAudioIn.contains(ext) { return .audio }
        if nativeVideoIn.contains(ext) { return .video }
        if ffmpegAudioIn.contains(ext) { return Tools.ffmpeg != nil ? .audio : .unknown }
        if ffmpegVideoIn.contains(ext) { return Tools.ffmpeg != nil ? .video : .unknown }
        if ext == "csv" || ext == "tsv" { return .table }
        if ext == "json" { return .json }
        if ext == "plist" { return .plist }
        if sheetsIn.contains(ext) { return Tools.soffice != nil ? .sheet : .unknown }
        if slidesIn.contains(ext) { return Tools.soffice != nil ? .slides : .unknown }
        return .unknown
    }

    /// Everything this file can turn into, grouped for the wheel. Empty means "can't convert this".
    static func groups(for url: URL) -> [Group] {
        let ext = canonical(url.pathExtension)
        let ffmpeg = Tools.ffmpeg != nil, office = Tools.soffice != nil
        var out: [Group] = []
        func add(_ category: Category, _ list: [String]) {
            let formats = list.filter { $0 != ext }
            if !formats.isEmpty { out.append(Group(category: category, formats: formats)) }
        }
        switch kind(ext) {
        case .image, .gif:
            add(.image, ["jpg", "png", "heic", "webp", "tiff", "gif", "bmp"].filter(canWriteImage))
            add(.document, ["pdf"])
            if ext == "gif" { add(.video, ["mp4", "mov"]) }
        case .pdf:
            add(.image, ["png", "jpg", "tiff", "heic"].filter(canWriteImage))
            add(.document, ["docx", "txt", "rtf", "html"])
        case .doc:
            add(.document, ["pdf", "docx", "rtf", "txt", "html", "odt"] + (Tools.pandoc != nil ? ["md"] : []))
            add(.image, ["png", "jpg"])
        case .audio:
            add(.audio, (ffmpeg ? ["mp3"] : []) + ["m4a", "wav", "aiff", "flac"] + (ffmpeg ? ["ogg"] : []))
        case .video:
            add(.video, ["mp4", "mov", "m4v"] + (ffmpeg ? ["webm", "mkv"] : []))
            add(.audio, (ffmpeg ? ["mp3"] : []) + ["m4a", "wav"])
            add(.image, ["gif"])
        case .table:
            add(.data, ["csv", "tsv", "json"] + (office ? ["xlsx"] : []))
            if office { add(.document, ["pdf"]) }
        case .json:
            add(.data, ["plist", "csv"])
        case .plist:
            add(.data, ["json"])
        case .sheet:
            add(.data, ["csv", "xlsx", "ods"])
            add(.document, ["pdf"])
        case .slides:
            add(.document, ["pdf", "pptx", "odp"])
        case .unknown:
            break
        }
        return out
    }

    /// Shown in the wheel when a file has nowhere to go.
    static func deadEndMessage(for url: URL) -> String {
        let ext = canonical(url.pathExtension)
        if ext.isEmpty { return "This file has no extension, so Morph can't tell what it is." }
        if sheetsIn.contains(ext) || slidesIn.contains(ext) {
            return "Install the free LibreOffice app and Morph can convert .\(ext) files."
        }
        if ffmpegAudioIn.contains(ext) || ffmpegVideoIn.contains(ext) {
            return "Install ffmpeg (brew install ffmpeg) and Morph can convert .\(ext) files."
        }
        return "Morph can't convert .\(ext) files."
    }
}
