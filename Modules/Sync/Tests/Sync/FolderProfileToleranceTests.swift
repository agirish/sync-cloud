import Foundation
import Testing
@testable import Sync

/// One unknown `role` string must not fail the whole profile. `FolderRole` is a raw-value enum, and
/// `role` being optional only makes an absent key fine: a present value with no case throws
/// `dataCorrupted`, which escapes `decodeIfPresent` and any `??` beside it. One entry from a newer
/// generator would then fail the profile, and with it everything `SyncCloudApp` loads behind it
/// (memory, people and tag stores, the content index). The app can't repair it, because
/// `writeProfile` refuses to overwrite, and the schema probe doesn't catch a new role inside the
/// current schema.
@Suite struct FolderProfileToleranceTests {

    static func json(roles: [String]) -> Data {
        let entries = roles.enumerated().map { i, role in
            """
            {"path":"F\(i)","role":\(role),"naming":null,"anchors":["a"],"acceptsNewFiles":null,
             "fileCount":\(i + 1),"subfolderCount":0,"axes":{"person":"Daughter"}}
            """
        }.joined(separator: ",")
        return Data("""
        {"profileId":"p","root":"~/Documents","folders":[\(entries)]}
        """.utf8)
    }

    @Test func oneUnknownRoleCostsThatFoldersRoleAndNothingElse() throws {
        let profile = try JSONDecoder().decode(
            FolderProfile.self,
            from: Self.json(roles: ["\"destination\"", "\"scratchpad-of-the-future\"", "\"container\""]))

        #expect(profile.folders.count == 3, "an unknown role took other folders with it")
        #expect(profile.folders["F0"]?.role == .destination)
        #expect(profile.folders["F2"]?.role == .container)
        // The unknown one is present and role-less, which is what "the survey said nothing" means
        // everywhere else, rather than a folder that vanished.
        let unknown = try #require(profile.folders["F1"])
        #expect(unknown.role == nil)
        // ...and it keeps every field this build does understand.
        #expect(unknown.fileCount == 2)
        #expect(unknown.anchors == ["a"])
        #expect(unknown.axes["person"] == "Daughter")
    }

    /// The count and the string are carried out, because a folder silently demoted to "no role"
    /// files differently and nothing else on screen would say so.
    @Test func theUnknownRolesAreReportedNotSwallowed() throws {
        let profile = try JSONDecoder().decode(
            FolderProfile.self,
            from: Self.json(roles: ["\"scratchpad-of-the-future\"", "\"destination\"",
                                    "\"scratchpad-of-the-future\"", "\"vault\""]))
        #expect(profile.unknownRoles == ["scratchpad-of-the-future": 2, "vault": 1])
        #expect(profile.undecodableFolders == 0)
    }

    /// A missing role is still just a missing role: the tolerance must not report every role-less
    /// folder as a surprise.
    @Test func anAbsentRoleIsNotAnUnknownRole() throws {
        let profile = try JSONDecoder().decode(FolderProfile.self,
                                               from: Self.json(roles: ["null", "\"destination\""]))
        #expect(profile.folders.count == 2)
        #expect(profile.folders["F0"]?.role == nil)
        #expect(profile.unknownRoles.isEmpty, "an absent role was reported as unknown")
    }

    /// An entry that can't be read even leniently costs itself, not the file, and is counted, so
    /// "the profile loaded" never quietly means "most of it did".
    @Test func anUndecodableEntryCostsOnlyItself() throws {
        let data = Data("""
        {"profileId":"p","root":"~","folders":[
          {"path":"A","role":"destination","naming":null,"anchors":[],"acceptsNewFiles":null,
           "fileCount":1,"subfolderCount":0,"axes":{}},
          "not even an object",
          {"path":"C","role":"container","naming":null,"anchors":[],"acceptsNewFiles":null,
           "fileCount":1,"subfolderCount":0,"axes":{}}
        ]}
        """.utf8)
        let profile = try JSONDecoder().decode(FolderProfile.self, from: data)
        #expect(profile.folders.keys.sorted() == ["A", "C"])
        #expect(profile.undecodableFolders == 1)
    }

    /// The person axis still comes through: the axis block is read from the same container as the
    /// leniently decoded folders array.
    @Test func thePersonAxisSurvivesTheNewFolderDecode() throws {
        let data = Data("""
        {"profileId":"p","root":"~","folders":[],
         "axes":{"person":{"values":["Granny"],"aliases":{"Mom":"Granny"}}}}
        """.utf8)
        let profile = try JSONDecoder().decode(FolderProfile.self, from: data)
        #expect(profile.personTokens.contains("granny"))
        #expect(profile.personAliases["mom"] == "granny")
    }
}
