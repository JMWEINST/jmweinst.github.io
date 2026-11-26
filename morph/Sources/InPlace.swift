import Foundation

/// Converts a file and leaves the result exactly where the original was.
///
/// Finder remembers where an icon sits by the file itself, not its name. So rather than deleting
/// the original and dropping a new file beside it (which makes the icon jump to the next free
/// slot), the converted contents are written *into* the original file, which is then renamed to
/// its new extension. Same file, same spot, new format. A copy of the original goes to the Trash.
enum Pipeline {
    @discardableResult
    static func convertInPlace(_ src: URL, to dst: String) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else {
            throw ConvertError("That file isn't there any more.")
        }
        guard fm.isWritableFile(atPath: src.path), fm.isWritableFile(atPath: src.deletingLastPathComponent().path) else {
            throw ConvertError("This file is locked or read-only, so it can't be changed.")
        }

        let work = fm.temporaryDirectory.appendingPathComponent("morph-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let base = src.deletingPathExtension().lastPathComponent
        let converted = work.appendingPathComponent(base + "." + dst)
        try Converter.convert(src, to: dst, out: converted)
        guard Converter.fileSize(converted) > 0 else { throw ConvertError("The conversion produced an empty file.") }

        // Never overwrite a different file that already has the name we want.
        let folder = src.deletingLastPathComponent()
        var dest = folder.appendingPathComponent(base + "." + dst)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) \(n).\(dst)")
            n += 1
        }

        // Keep the original recoverable before touching it.
        let safe = work.appendingPathComponent("original")
        try fm.createDirectory(at: safe, withIntermediateDirectories: true)
        let backup = safe.appendingPathComponent(src.lastPathComponent)
        try fm.copyItem(at: src, to: backup)

        do {
            try overwrite(src, with: converted)
        } catch {
            try? overwrite(src, with: backup)
            throw ConvertError("Couldn't write the converted file: \(error.localizedDescription)")
        }
        do {
            try fm.moveItem(at: src, to: dest)
        } catch {
            try? overwrite(src, with: backup)
            throw ConvertError("Couldn't rename the file: \(error.localizedDescription)")
        }

        if (try? fm.trashItem(at: backup, resultingItemURL: nil)) == nil {
            // No Trash on this volume: leave the original next to the new file instead of losing it.
            let keep = folder.appendingPathComponent("\(base) (original).\(src.pathExtension)")
            try? fm.moveItem(at: backup, to: keep)
        }
        return dest
    }

    /// Replaces a file's contents without replacing the file.
    static func overwrite(_ target: URL, with source: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        while true {
            let chunk = input.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }
}
