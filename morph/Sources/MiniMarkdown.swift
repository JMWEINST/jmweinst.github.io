import Foundation

/// Just enough Markdown to turn notes and READMEs into real documents: headings, lists,
/// quotes, code, rules, links, bold and italic.
enum MiniMarkdown {
    static func html(_ markdown: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var list: String?
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                out.append("<p>" + inline(paragraph.joined(separator: " ")) + "</p>")
                paragraph = []
            }
        }
        func closeList() {
            if let tag = list { out.append("</\(tag)>"); list = nil }
        }
        func item(_ tag: String, _ text: String) {
            flushParagraph()
            if list != tag { closeList(); out.append("<\(tag)>"); list = tag }
            out.append("<li>" + inline(text) + "</li>")
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    out.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                    code = []
                    inCode = false
                } else {
                    flushParagraph(); closeList(); inCode = true
                }
                continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty { flushParagraph(); closeList(); continue }

            let hashes = line.prefix { $0 == "#" }.count
            if hashes >= 1, hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") {
                flushParagraph(); closeList()
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                out.append("<h\(hashes)>" + inline(text) + "</h\(hashes)>")
            } else if line == "---" || line == "***" || line == "___" {
                flushParagraph(); closeList(); out.append("<hr>")
            } else if line.hasPrefix(">") {
                flushParagraph(); closeList()
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                out.append("<blockquote>" + inline(text) + "</blockquote>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                item("ul", String(line.dropFirst(2)))
            } else if let r = line.range(of: "^[0-9]+[.)] ", options: .regularExpression) {
                item("ol", String(line[r.upperBound...]))
            } else {
                paragraph.append(line)
            }
        }
        if inCode { out.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>") }
        flushParagraph(); closeList()

        let style = """
        body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px;line-height:1.45}
        code,pre{font-family:Menlo,monospace;font-size:12px}
        blockquote{color:#555;margin-left:1em}
        """
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>\(style)</style></head><body>\n"
            + out.joined(separator: "\n") + "\n</body></html>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ text: String) -> String {
        var s = escape(text)
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
            ("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>"),
            ("\\*\\*(.+?)\\*\\*", "<b>$1</b>"),
            ("__(.+?)__", "<b>$1</b>"),
            ("\\*(.+?)\\*", "<i>$1</i>"),
            ("(?<![A-Za-z0-9])_(.+?)_(?![A-Za-z0-9])", "<i>$1</i>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }
}
