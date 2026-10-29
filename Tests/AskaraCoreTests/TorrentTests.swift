import Foundation
import Testing
@testable import AskaraCore

@Suite struct TorrentTests {
    @Test func recognisesMagnetLinks() {
        #expect(TorrentLink.isMagnet(URL(string: "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=Ubuntu")!))
        #expect(!TorrentLink.isMagnet(URL(string: "magnet:?dn=NoHash")!))
        #expect(!TorrentLink.isMagnet(URL(string: "https://example.com/?xt=urn:btih:abc")!))
    }

    @Test func recognisesTorrentFiles() {
        #expect(TorrentLink.isTorrentFile(URL(string: "https://example.com/a/ubuntu.TORRENT")!))
        #expect(TorrentLink.isTorrentFile(URL(string: "https://example.com/dl?id=1")!, mimeType: "application/x-bittorrent"))
        #expect(!TorrentLink.isTorrentFile(URL(string: "file:///tmp/a.torrent")!))
        #expect(!TorrentLink.isTorrentFile(URL(string: "https://example.com/a.zip")!))
    }

    @Test func magnetDisplayNameIsSanitized() {
        let url = URL(string: "magnet:?xt=urn:btih:abc123&dn=../evil%2Fname")!
        let name = TorrentLink.displayName(of: url)
        #expect(name?.contains("/") == false)
        #expect(name?.hasPrefix(".") == false)
        #expect(TorrentLink.displayName(of: URL(string: "magnet:?xt=urn:btih:abc123")!) == nil)
    }

    @Test func parsesProgressAndFileLines() {
        var parser = TorrentOutputParser()
        let text = "[#3fc556 2179072B/8000000B(27%) CN:1 SD:0 DL:1070797B ETA:5s]\nFILE: /tmp/out/sample.bin\n"
        let events = parser.feed(Data(text.utf8))
        #expect(events == [.progress(completed: 2_179_072, total: 8_000_000, bytesPerSecond: 1_070_797),
                           .file("/tmp/out/sample.bin")])
    }

    @Test func keepsPartialLinesBetweenChunks() {
        var parser = TorrentOutputParser()
        #expect(parser.feed(Data("[#a1 10B/20B(50%) CN:1 DL:".utf8)).isEmpty)
        #expect(parser.feed(Data("5B ETA:1s]\r".utf8)) == [.progress(completed: 10, total: 20, bytesPerSecond: 5)])
    }

    @Test func ignoresMetadataPlaceholdersAndReportsErrors() {
        #expect(TorrentOutputParser.parse(line: "FILE: [MEMORY]ubuntu.torrent") == nil)
        #expect(TorrentOutputParser.parse(line: "[#a1 0B/0B CN:0 SD:0 DL:0B]") == .progress(completed: 0, total: 0, bytesPerSecond: 0))
        #expect(TorrentOutputParser.parse(line: "  -> [NameResolver.cc:60] errorCode=19 Failed to resolve the hostname x.info, cause: not known") == .error("Failed to resolve the hostname x.info, cause: not known"))
        #expect(TorrentOutputParser.parse(line: "Exception: [AbstractCommand.cc:351] errorCode=19 URI=http://x/announce?a=1") == nil)
    }

    @Test func topLevelItemIsFileOrTorrentFolder() {
        let dir = URL(fileURLWithPath: "/Users/me/Downloads")
        #expect(TorrentOutputParser.topLevelItem(of: "/Users/me/Downloads/a.iso", in: dir)?.path == "/Users/me/Downloads/a.iso")
        #expect(TorrentOutputParser.topLevelItem(of: "/Users/me/Downloads/Album/01.mp3", in: dir)?.path == "/Users/me/Downloads/Album")
        #expect(TorrentOutputParser.topLevelItem(of: "/etc/passwd", in: dir) == nil)
        #expect(TorrentOutputParser.topLevelItem(of: "/Users/me/Downloads/../x/a", in: dir) == nil)
    }
}

@Suite struct TorrentSafetyTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askara-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Album/Extras"), withIntermediateDirectories: true)
        return root
    }

    @Test func folderScanFindsRisksAndSizes() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("Album/01.mp3"))
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("Album/Extras/run.sh"))
        // Mach-O magic behind a harmless name.
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0]).write(to: root.appendingPathComponent("Album/readme.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Album/link"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))

        let scan = DownloadFolderScanner.scan(root)
        #expect(scan.fileCount == 3)
        #expect(scan.size == 10 + 10 + 6)
        #expect(Set(scan.risks) == [.script, .disguisedExecutable, .executable])
        #expect(!scan.truncated)
    }

    @Test func folderScanOfHarmlessFilesHasNoRisks() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 7, count: 100).write(to: root.appendingPathComponent("Album/01.mp3"))
        #expect(DownloadFolderScanner.scan(root).risks.isEmpty)
    }

    @Test func folderScanStopsAtTheEntryLimit() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 0..<5 { try Data([1]).write(to: root.appendingPathComponent("Album/\(n).txt")) }
        #expect(DownloadFolderScanner.scan(root, maxEntries: 3).truncated)
    }

    @Test func quarantineMarksFilesAndSkipsSymlinks() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Album/Extras/a.bin")
        try Data([1, 2, 3]).write(to: file)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("askara-\(UUID().uuidString).txt")
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Album/link"), withDestinationURL: outside)

        DownloadQuarantine.apply(to: root, agentName: "Askara", sourceURL: URL(string: "magnet:?xt=urn:btih:abc"))
        #expect(DownloadQuarantine.isQuarantined(file))
        #expect(DownloadQuarantine.isQuarantined(root.appendingPathComponent("Album")))
        #expect(!DownloadQuarantine.isQuarantined(outside))
    }
}

@Suite struct TorrentSandboxTests {
    /// Runs `/bin/bash -c command` under the profile (not /bin/sh: it re-executes bash, which the profile forbids), with a temporary folder standing in for the home folder.
    private func run(_ command: String, home: URL, downloads: URL, support: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = TorrentSandbox.executable
        process.arguments = TorrentSandbox.arguments(
            home: home, downloads: downloads, support: support,
            engine: URL(fileURLWithPath: "/bin/bash"), engineArguments: ["-c", command])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test(.enabled(if: TorrentSandbox.isAvailable))
    func engineCannotTouchFilesOutsideItsFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askara-sb-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home"), downloads = home.appendingPathComponent("Downloads")
        let support = home.appendingPathComponent("State"), secret = home.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: secret)
        try Data("movie".utf8).write(to: downloads.appendingPathComponent("a.bin"))
        defer { try? FileManager.default.removeItem(at: root) }
        let real = URL(fileURLWithPath: TorrentSandbox.realPath(home))

        // Shell built-ins only: the profile forbids starting other programs such as cat.
        // Allowed: read and write the download folder, write the state folder.
        #expect(try run("read -r -n 5 line < '\(real.path)/Downloads/a.bin' && echo x > '\(real.path)/Downloads/b.bin' && echo x > '\(real.path)/State/dht.dat'",
                        home: home, downloads: downloads, support: support) == 0)
        // Denied: read a file elsewhere in the home folder, and write there.
        #expect(try run("read line < '\(real.path)/secret.txt'", home: home, downloads: downloads, support: support) != 0)
        #expect(try run("echo x > '\(real.path)/planted.txt'", home: home, downloads: downloads, support: support) != 0)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("planted.txt").path))
        // Denied: starting another program.
        #expect(try run("/bin/ls /", home: home, downloads: downloads, support: support) != 0)
    }
}
