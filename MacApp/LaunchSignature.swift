import Foundation
import Security

/// How the running build is signed — logged once per launch, because it decides whether macOS's
/// privacy grants survive the next rebuild.
///
/// macOS keys a privacy grant (Documents access; the Keychain's trust in the Anthropic key) to the
/// app's designated requirement. An ad-hoc build's requirement is its cdhash, which moves with every
/// build, so each ad-hoc install is a new app to macOS and the iCloud pane waits behind the
/// Documents-access dialog again — speed audit P16. A build signed with a team's certificate is
/// named by that certificate instead, and the grant carries over. `install-sync-cloud` signs the
/// installed copy; this line is how a reader of `~/sync-cloud.log` tells which kind of build a
/// session ran, without `codesign` or a live `tccd` stream. Until it existed, answering that for a
/// past session took the system log, whose detailed lines age out within about a day.
enum LaunchSignature: Equatable {
    /// Signed with a team's certificate; carries the team identifier.
    case team(String)
    /// Ad-hoc — Xcode's "Sign to Run Locally", or the linker's own signature.
    case adHoc
    /// Signed with a certificate that has no team identifier.
    case noTeam
    /// Not signed at all.
    case unsigned
    /// The signature could not be read.
    case unreadable(OSStatus)

    /// What `SecCodeCopySigningInformation` reported, classified.
    ///
    /// Separate from ``current()`` so every case can be tested: the test host is only ever ad-hoc.
    /// The ad-hoc test reads one flag rather than comparing the whole word, because the linker's
    /// own signature sets a second one beside it (`0x20002` rather than `0x2`, measured).
    static func classify(isSigned: Bool, teamIdentifier: String?, flags: UInt32?) -> LaunchSignature {
        guard isSigned else { return .unsigned }
        if let teamIdentifier, !teamIdentifier.isEmpty { return .team(teamIdentifier) }
        if let flags, SecCodeSignatureFlags(rawValue: flags).contains(.adhoc) { return .adHoc }
        return .noTeam
    }

    /// The running process's own signature. A few milliseconds: 1.25 ms cold in a small probe, and
    /// the installed app's two launch lines landed 5 ms apart (both measured 2026-09-26).
    static func current() -> LaunchSignature {
        var code: SecCode?
        var status = SecCodeCopySelf(SecCSFlags(), &code)
        guard status == errSecSuccess, let code else { return .unreadable(status) }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else { return .unreadable(status) }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            return .unreadable(status)
        }
        return classify(
            isSigned: info[kSecCodeInfoIdentifier as String] != nil,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            flags: (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value)
    }

    /// The launch breadcrumb. Only the ad-hoc case says what it costs, because it is the only one
    /// that sends the next launch back to the Documents-access dialog.
    var logLine: String {
        switch self {
        case .team(let team):
            return "Code signature: team \(team) — privacy grants carry over to the next build"
        case .adHoc:
            return "Code signature: ad-hoc — each rebuild is a new app to macOS privacy, "
                + "so its first launch asks for Documents access again"
        case .noTeam:
            return "Code signature: a certificate with no team"
        case .unsigned:
            return "Code signature: unsigned"
        case .unreadable(let status):
            return "Code signature: unreadable (OSStatus \(status))"
        }
    }
}
