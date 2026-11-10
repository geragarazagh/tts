// Any text file to plain text, with the system's own readers: AppKit for plain text, RTF, Word, OpenDocument, HTML and
// web archives, PDFKit for PDF, Foundation's Markdown parser for Markdown (its syntax goes, its words stay).

import AppKit
import PDFKit
import UniformTypeIdentifiers

enum TextImport {
    static let types: [UTType] = [.plainText, .rtf, .rtfd, .html, .pdf, .webArchive,
                                  UTType("net.daringfireball.markdown"), UTType("org.openxmlformats.wordprocessingml.document"),
                                  UTType("com.microsoft.word.doc"), UTType("org.oasis-open.opendocument.text")].compactMap { $0 }

    static func read(_ url: URL) throws -> String {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        var text: String
        if let t = type, t.conforms(to: .pdf) {
            guard let d = PDFDocument(url: url) else { throw EngineError(description: url.path) }
            text = d.string ?? ""
        } else if ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
                    || type?.identifier == "net.daringfireball.markdown" {
            text = markdown(try String(contentsOf: url))
        } else if let t = type, t.conforms(to: .plainText) {
            var enc = String.Encoding.utf8
            if let t = try? String(contentsOf: url, usedEncoding: &enc) { text = t } else { text = try String(contentsOf: url, encoding: .windowsCP1251) }
            if looksLikeMarkdown(text) { text = markdown(text) }
        } else {
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        }
        return tidy(text)
    }

    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{00AD}", with: "")
        t = t.replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Two or more marks that plain prose doesn't have.
    static func looksLikeMarkdown(_ s: String) -> Bool {
        let marks = ["(?m)^#{1,6} \\S", "\\*\\*[^*\\n]+\\*\\*", "\\[[^\\]\\n]+\\]\\([^)\\s]+\\)", "(?m)^```", "(?m)^> \\S",
                     "(?m)^\\s*[-*+] \\S", "`[^`\\n]+`", "__[^_\\n]+__"]
        return marks.filter { s.range(of: $0, options: .regularExpression) != nil }.count >= 2
    }

    static func markdown(_ s: String) -> String {
        guard let a = try? AttributedString(markdown: s, options: .init(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                                          failurePolicy: .returnPartiallyParsedIfPossible)) else { return s }
        var out = ""
        var lastBlock: Int?
        var lastWasListItem = false
        for run in a.runs {
            let intent = run.presentationIntent
            let block = intent?.components.first?.identity
            let isItem = intent?.components.contains { if case .listItem = $0.kind { return true } else { return false } } ?? false
            if let b = block, b != lastBlock, lastBlock != nil {
                out += (isItem && lastWasListItem) ? "\n" : "\n\n"
            }
            if let b = block { lastBlock = b }
            lastWasListItem = isItem
            out += String(a[run.range].characters)
        }
        return out
    }
}
