import Foundation

/// Builds the Reader page. Only text and image addresses from `ReaderArticle` are used, and all text is
/// escaped, so nothing from the original page can run script. The CSP blocks scripts, frames, and
/// network requests other than images, as a second layer.
public enum ReaderDocument {
    public static let contentSecurityPolicy =
        "default-src 'none'; img-src http: https:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"

    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// `minutesLabel` is localized by the caller ("3 min read").
    public static func html(for article: ReaderArticle, minutesLabel: String? = nil) -> String {
        var body = ""
        var openList = false
        func closeList() {
            if openList { body += "</ul>\n"; openList = false }
        }
        for block in article.blocks {
            if case .listItem = block {} else { closeList() }
            switch block {
            case let .heading(level, text):
                // The page title is the only h1; headings inside the text start at h2.
                let tag = "h\(min(max(level, 2), 6))"
                body += "<\(tag)>\(escape(text))</\(tag)>\n"
            case let .paragraph(text):
                body += "<p>\(escape(text))</p>\n"
            case let .listItem(text):
                if !openList { body += "<ul>\n"; openList = true }
                body += "<li>\(escape(text))</li>\n"
            case let .quote(text):
                body += "<blockquote>\(escape(text))</blockquote>\n"
            case let .code(text):
                body += "<pre><code>\(escape(text))</code></pre>\n"
            case let .image(url, alt):
                body += "<figure><img src=\"\(escape(url.absoluteString))\" alt=\"\(escape(alt))\" loading=\"lazy\"></figure>\n"
            }
        }
        closeList()

        var meta: [String] = []
        if !article.siteName.isEmpty { meta.append(escape(article.siteName)) }
        if !article.byline.isEmpty { meta.append(escape(article.byline)) }
        if let minutesLabel, !minutesLabel.isEmpty { meta.append(escape(minutesLabel)) }
        let metaLine = meta.isEmpty ? "" : "<p class=\"meta\">\(meta.joined(separator: " · "))</p>\n"
        let title = article.title.isEmpty ? "Reader" : article.title

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 48px 24px 96px; font: 19px/1.65 -apple-system, "Helvetica Neue", sans-serif;
               background: Canvas; color: CanvasText; -webkit-font-smoothing: antialiased; }
        article { max-width: 680px; margin: 0 auto; overflow-wrap: anywhere; }
        h1 { font-size: 2em; line-height: 1.2; margin: 0 0 .3em; }
        h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.6em 0 .5em; }
        .meta { color: GrayText; font-size: .8em; margin: 0 0 2em; }
        p { margin: 0 0 1em; }
        ul { padding-left: 1.4em; margin: 0 0 1em; }
        li { margin: .3em 0; }
        blockquote { margin: 1em 0; padding: 0 0 0 1em; border-left: 3px solid GrayText; color: GrayText; }
        pre { overflow-x: auto; padding: 12px; border-radius: 8px; font-size: .8em; line-height: 1.5;
              background: color-mix(in srgb, CanvasText 8%, Canvas); }
        figure { margin: 1.5em 0; }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        </style>
        </head>
        <body>
        <article>
        <h1>\(escape(title))</h1>
        \(metaLine)\(body)</article>
        </body>
        </html>
        """
    }
}
