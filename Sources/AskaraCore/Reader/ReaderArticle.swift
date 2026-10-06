import Foundation

/// The readable content of a page, as extracted by the Reader script. The script runs on an untrusted
/// page, so everything here is treated as plain text and limited in size before it is shown.
public struct ReaderArticle: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(String)
        case quote(String)
        case code(String)
        case image(url: URL, alt: String)
    }

    public var title: String
    public var byline: String
    public var siteName: String
    public var blocks: [Block]

    public static let maxBlocks = 3_000
    public static let maxTextLength = 20_000
    /// Minimum amount of paragraph text for a page to count as an article.
    public static let minimumReadableCharacters = 280

    public init(title: String, byline: String = "", siteName: String = "", blocks: [Block]) {
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.blocks = blocks
    }

    /// Parses the dictionary returned by the Reader script. nil if it isn't shaped like one.
    public init?(payload: Any?) {
        guard let dict = payload as? [String: Any], let raw = dict["blocks"] as? [[String: Any]] else { return nil }
        func text(_ value: Any?, limit: Int = ReaderArticle.maxTextLength) -> String {
            Self.clean(value as? String ?? "", limit: limit)
        }
        var parsed: [Block] = []
        for entry in raw.prefix(Self.maxBlocks) {
            switch entry["t"] as? String {
            case "h":
                let body = text(entry["text"])
                let level = min(max((entry["level"] as? Int) ?? (entry["level"] as? NSNumber)?.intValue ?? 2, 1), 6)
                if !body.isEmpty { parsed.append(.heading(level: level, text: body)) }
            case "p":
                let body = text(entry["text"])
                if !body.isEmpty { parsed.append(.paragraph(body)) }
            case "li":
                let body = text(entry["text"])
                if !body.isEmpty { parsed.append(.listItem(body)) }
            case "q":
                let body = text(entry["text"])
                if !body.isEmpty { parsed.append(.quote(body)) }
            case "pre":
                // Code keeps its line breaks and indentation.
                let body = Self.clean(entry["text"] as? String ?? "", limit: Self.maxTextLength, keepLayout: true)
                if !body.isEmpty { parsed.append(.code(body)) }
            case "img":
                if let source = entry["src"] as? String, let url = URL(string: source),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                    parsed.append(.image(url: url, alt: text(entry["text"], limit: 300)))
                }
            default:
                continue
            }
        }
        title = text(dict["title"], limit: 300)
        byline = text(dict["byline"], limit: 200)
        siteName = text(dict["siteName"], limit: 100)
        // The page title is already shown above the text; don't repeat it as the first heading.
        if case let .heading(_, first)? = parsed.first, !title.isEmpty,
           first.caseInsensitiveCompare(title) == .orderedSame {
            parsed.removeFirst()
        }
        blocks = parsed
    }

    /// Enough running text to be worth showing in Reader (not a menu, a login form, or a feed).
    public var isReadable: Bool {
        let characters = blocks.reduce(0) { total, block in
            if case let .paragraph(text) = block { return total + text.count }
            return total
        }
        return characters >= Self.minimumReadableCharacters
    }

    /// Rough reading time at 200 words per minute, at least one minute.
    public var readingMinutes: Int {
        let words = blocks.reduce(0) { total, block in
            switch block {
            case let .paragraph(text), let .listItem(text), let .quote(text), let .heading(_, text):
                return total + text.split(whereSeparator: \.isWhitespace).count
            default: return total
            }
        }
        return max(1, Int((Double(words) / 200).rounded()))
    }

    static func clean(_ raw: String, limit: Int, keepLayout: Bool = false) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                scalars.append(keepLayout ? scalar : " ")
            } else if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        var text = String(scalars)
        if !keepLayout {
            text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        } else {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.count > limit ? String(text.prefix(limit)) : text
    }
}
