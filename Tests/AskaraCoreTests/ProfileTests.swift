import Foundation
import Testing
@testable import AskaraCore

@Suite struct ProfileTests {
    @Test func startsWithDefaultProfile() {
        let list = ProfileList(defaultName: "Main")
        #expect(list.profiles.count == 1)
        #expect(list.lastUsed.isDefault)
        #expect(list.lastUsed.folder == "")
        #expect(list.lastUsed.browserEngine == .webkit)
    }

    @Test func engineBelongsToProfileAndOldFilesDefaultToWebKit() throws {
        var list = ProfileList(defaultName: "Main")
        let result = list.add(name: "Chromium", browserEngine: .blink)
        let added = try #require(result)
        #expect(added.browserEngine == .blink)
        let updated = list.update(added.id, name: added.name, colorIndex: added.colorIndex,
                                  browserEngine: .gecko)
        #expect(updated)
        #expect(list.profile(added.id)?.browserEngine == .gecko)

        let id = UUID()
        let oldJSON = #"{"id":"\#(id.uuidString)","name":"Old","colorIndex":0}"#
        let old = try JSONDecoder().decode(Profile.self, from: Data(oldJSON.utf8))
        #expect(old.browserEngine == .webkit)
    }

    @Test func initials() {
        #expect(Profile(name: "Kerja Kantor", colorIndex: 0).initials == "KK")
        #expect(Profile(name: "aditya", colorIndex: 0).initials == "A")
        #expect(Profile(name: "a b c", colorIndex: 0).initials == "AB")
    }

    @Test func addUsesUnusedColorsAndOwnFolder() throws {
        var list = ProfileList(defaultName: "Main")
        let added = list.add(name: "  Work  ")
        let work = try #require(added)
        #expect(work.name == "Work")
        #expect(work.colorIndex == 1)
        #expect(work.folder == "Profiles/\(work.id.uuidString)/")
        let empty = list.add(name: "   ")
        #expect(empty == nil)
    }

    @Test func defaultProfileCannotBeRemoved() throws {
        var list = ProfileList(defaultName: "Main")
        let removedDefault = list.remove(Profile.defaultID)
        #expect(!removedDefault)
        let added = list.add(name: "Work")
        let work = try #require(added)
        list.markUsed(work.id)
        let removed = list.remove(work.id)
        #expect(removed)
        #expect(list.lastUsedID == Profile.defaultID)
        #expect(list.pendingRemovals == [work.id])
        list.storeRemoved(work.id)
        #expect(list.pendingRemovals.isEmpty)
    }

    @Test func markUsedReportsChange() throws {
        var list = ProfileList(defaultName: "Main")
        let added = list.add(name: "Work")
        let work = try #require(added)
        let first = list.markUsed(work.id)
        let again = list.markUsed(work.id)
        let unknown = list.markUsed(UUID())
        #expect(first)
        #expect(!again)
        #expect(!unknown)
        #expect(list.lastUsed == work)
    }

    @Test func decodeRepairsFile() throws {
        let other = UUID()
        let json = #"{"profiles":[{"id":"\#(other.uuidString)","name":"B","colorIndex":2},{"id":"\#(other.uuidString)","name":"dup","colorIndex":3}],"lastUsedID":"\#(UUID().uuidString)"}"#
        let list = try JSONDecoder().decode(ProfileList.self, from: Data(json.utf8))
        #expect(list.profiles.map(\.id) == [Profile.defaultID, other])
        #expect(list.lastUsedID == Profile.defaultID)
        #expect(list.pendingRemovals.isEmpty)
    }

    @Test func roundTrip() throws {
        var list = ProfileList(defaultName: "Main")
        let added = list.add(name: "Work")
        let work = try #require(added)
        list.update(work.id, name: "Kantor", colorIndex: 99)
        let decoded = try JSONDecoder().decode(ProfileList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
        #expect(decoded.profile(work.id)?.colorIndex == ProfileList.colorCount - 1)
    }
}
