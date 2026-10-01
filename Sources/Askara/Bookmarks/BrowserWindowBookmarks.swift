import Foundation

extension BrowserWindowController: BookmarkBarDelegate {
    var bookmarkBarProfile: ProfileData { profile }

    func bookmarkBar(_ bar: BookmarkBarView, open url: URL, newTab: Bool) {
        if newTab { self.newTab(url: url) } else { load(url) }
    }

    func bookmarkBar(_ bar: BookmarkBarView, openAll urls: [URL]) {
        urls.forEach { newTab(url: $0) }
    }
}
