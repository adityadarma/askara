import Foundation
import Testing
@testable import AskaraCore

@Suite struct ProfileTests {
    @Test func startsWithDefaultProfile() {
        let list = ProfileList(defaultName: "Main")
        #expect(list.profiles.count == 1)
        #expect(list.lastUsed.isDefault)
        #expect(list.lastUsed.folder == "")
    }

    @Test(arguments: ["webkit", "blink", "gecko", "unknown"])
    func legacyBrowserEngineIsIgnored(_ engine: String) throws {
        let id = UUID()
        let oldJSON = #"{"id":"\#(id.uuidString)","name":"Old","colorIndex":3,"browserEngineID":"\#(engine)"}"#
        let old = try JSONDecoder().decode(Profile.self, from: Data(oldJSON.utf8))
        #expect(old.id == id)
        #expect(old.name == "Old")
        #expect(old.colorIndex == 3)
        let encoded = try JSONEncoder().encode(old)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["browserEngineID"] == nil)
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
        let json = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
        #expect(!json.contains("browserEngineID"))
    }
}
