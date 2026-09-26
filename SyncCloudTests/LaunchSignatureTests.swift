import Foundation
import Security
import Testing
@testable import SyncCloud

/// The launch line that says how the running build is signed.
///
/// **It exists because speed audit P16 had no trace in the app's own log.** Fifteen of sixteen
/// launches on 2026-09-25 waited behind the Documents-access dialog because every ad-hoc build is a
/// new app to macOS privacy, and establishing that took `codesign`, the system log and a live `tccd`
/// stream — the log only ever said "launched". These pin the classification that line reports and
/// the wording a log reader greps for.
///
/// Only one branch can be reached for real: the test host is built ad-hoc, like every build here
/// (`project.yml` pins `CODE_SIGN_IDENTITY: "-"` for every target). The others go through
/// `classify`, which takes what `SecCodeCopySigningInformation` would have reported.
@Suite struct LaunchSignatureTests {

    /// A made-up team: the repository is public, and the real one is not needed to test the branch.
    private static let team = "ABCDE12345"

    @Test func aTeamCertificateIsReportedByItsTeam() {
        #expect(LaunchSignature.classify(isSigned: true, teamIdentifier: Self.team, flags: 0)
                == .team(Self.team))
    }

    /// Ad-hoc is read from its one flag, not from the whole word: the linker's own signature sets a
    /// second flag beside it, and a comparison against `0x2` alone would call that build "no team".
    @Test func adHocIsReadFromItsFlagNotTheWholeWord() {
        #expect(LaunchSignature.classify(isSigned: true, teamIdentifier: nil, flags: 0x2) == .adHoc)
        #expect(LaunchSignature.classify(isSigned: true, teamIdentifier: nil, flags: 0x20002) == .adHoc,
                "a linker-signed build is ad-hoc too")
    }

    /// An empty team identifier is no team, so the flags decide.
    @Test func anEmptyTeamIsNoTeam() {
        #expect(LaunchSignature.classify(isSigned: true, teamIdentifier: "", flags: 0x2) == .adHoc)
        #expect(LaunchSignature.classify(isSigned: true, teamIdentifier: "", flags: 0) == .noTeam)
    }

    @Test func aSignatureWithNeitherIsItsOwnCase() {
        #expect(LaunchSignature.classify(isSigned: true, teamIdentifier: nil, flags: 0) == .noTeam)
        #expect(LaunchSignature.classify(isSigned: true, teamIdentifier: nil, flags: nil) == .noTeam)
    }

    /// Unsigned code must not be reported as signed by anything, whatever the flags say.
    @Test func unsignedCodeIsNeverReportedAsSigned() {
        #expect(LaunchSignature.classify(isSigned: false, teamIdentifier: nil, flags: 0x2) == .unsigned)
        #expect(LaunchSignature.classify(isSigned: false, teamIdentifier: Self.team, flags: 0)
                == .unsigned)
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

    /// The live path, read in this very process: the test host is built ad-hoc.
    ///
    /// This is also the check on `project.yml`'s pin. If the builds ever became certificate-signed,
    /// CI would suddenly need a keychain to build the app — and this would say so first.
    @Test func theTestHostIsAdHoc() {
        #expect(LaunchSignature.current() == .adHoc)
    }
}
