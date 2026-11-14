import Foundation
import Security
import Testing
@testable import SyncCloud

/// The launch line that says how the running build is signed. Every ad-hoc build is a new app to
/// macOS privacy and waits behind the Documents-access dialog at first launch, and without this
/// line only `codesign` and the system log can show why. These pin the classification and the
/// wording a log reader greps for. Only the ad-hoc branch is reachable for real (`project.yml` pins
/// `CODE_SIGN_IDENTITY: "-"`); the others go through `classify`, which takes what
/// `SecCodeCopySigningInformation` would report.
@Suite struct LaunchSignatureTests {

    /// A made-up team: the repository is public, and the real one is not needed to test the branch.
    static let team = "ABCDE12345"

    /// `classify`, case by case. Ad-hoc is read from its one flag, not the whole word: the linker's
    /// own signature sets a second flag beside it, and a comparison against `0x2` alone would call
    /// that build "no team".
    @Test(arguments: [
        (true, LaunchSignatureTests.team, 0, .team(LaunchSignatureTests.team)),
        (true, nil, 0x2, .adHoc),
        (true, nil, 0x20002, .adHoc),        // linker-signed is ad-hoc too
        (true, "", 0x2, .adHoc),             // an empty team is no team, so the flags decide
        (true, "", 0, .noTeam),
        (true, nil, 0, .noTeam),             // neither is its own case
        (true, nil, nil, .noTeam),
        (false, nil, 0x2, .unsigned),        // unsigned is never reported as signed, whatever the flags
        (false, LaunchSignatureTests.team, 0, .unsigned),
    ] as [(Bool, String?, UInt32?, LaunchSignature)])
    func classify(isSigned: Bool, team: String?, flags: UInt32?, expected: LaunchSignature) {
        #expect(LaunchSignature.classify(isSigned: isSigned, teamIdentifier: team, flags: flags) == expected)
    }

    /// The prefix is what a reader greps for; the ad-hoc line is the only one that says what it
    /// costs, because it is the only kind of build whose first launch asks for Documents access.
    @Test func theLinesCarryTheGreppablePrefixAndOnlyAdHocNamesTheCost() {
        let lines = [LaunchSignature.team(Self.team), .adHoc, .noTeam, .unsigned, .unreadable(-67050)]
            .map(\.logLine)
        for line in lines {
            #expect(line.hasPrefix("Code signature: "), "\(line)")
        }
        #expect(LaunchSignature.team(Self.team).logLine.contains(Self.team))
        #expect(LaunchSignature.adHoc.logLine.contains("ad-hoc"))
        #expect(lines.filter { $0.contains("Documents access") } == [LaunchSignature.adHoc.logLine])
        #expect(LaunchSignature.unreadable(-67050).logLine.contains("-67050"))
    }

    /// The live path, read in this process: the test host is built ad-hoc. This also checks
    /// `project.yml`'s pin: certificate-signed builds would need a keychain on CI, and this would
    /// say so first.
    @Test func theTestHostIsAdHoc() {
        #expect(LaunchSignature.current() == .adHoc)
    }
}
