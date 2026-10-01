import Foundation

/// A search engine for the address bar and "Search with…" in the context menu.
public struct SearchEngine: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// `%@` is replaced by the encoded query.
    public let searchTemplate: String
    public let homeURL: URL

    public init(id: String, name: String, searchTemplate: String, homeURL: URL) {
        self.id = id
        self.name = name
        self.searchTemplate = searchTemplate
        self.homeURL = homeURL
    }

    public static let all: [SearchEngine] = [
        SearchEngine(id: "google", name: "Google", searchTemplate: AddressParser.defaultSearchTemplate,
                     homeURL: AddressParser.defaultHomeURL),
        SearchEngine(id: "duckduckgo", name: "DuckDuckGo", searchTemplate: "https://duckduckgo.com/?q=%@",
                     homeURL: URL(string: "https://duckduckgo.com")!),
        SearchEngine(id: "bing", name: "Bing", searchTemplate: "https://www.bing.com/search?q=%@",
                     homeURL: URL(string: "https://www.bing.com")!),
        SearchEngine(id: "brave", name: "Brave Search", searchTemplate: "https://search.brave.com/search?q=%@",
                     homeURL: URL(string: "https://search.brave.com")!),
        SearchEngine(id: "ecosia", name: "Ecosia", searchTemplate: "https://www.ecosia.org/search?q=%@",
                     homeURL: URL(string: "https://www.ecosia.org")!),
        SearchEngine(id: "startpage", name: "Startpage", searchTemplate: "https://www.startpage.com/do/search?q=%@",
                     homeURL: URL(string: "https://www.startpage.com")!),
    ]

    public static func engine(id: String) -> SearchEngine { all.first { $0.id == id } ?? all[0] }

    public func searchURL(for query: String) -> URL? {
        AddressParser.searchURL(for: query, template: searchTemplate)
    }
}
