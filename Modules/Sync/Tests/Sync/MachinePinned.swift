import Foundation
import Testing

// NOTE: This helper is intentionally duplicated (verbatim) in the other four test
// targets — SPM offers no clean way to share test-support code across packages without
// minting a production library product, and the harness must stay test-only. If you change
// this file, change the copies too:
//   Modules/Dashboard/Tests/Dashboard/MachinePinned.swift
//   Modules/Design/Tests/DesignTests/MachinePinned.swift
//   Modules/FileExplorer/Tests/FileExplorer/MachinePinned.swift
//   Modules/Settings/Tests/Settings/MachinePinned.swift
/// Why a suite only produces a trustworthy verdict on the machine that recorded it.
///
/// These suites are not flaky and they are not wrong — they are *pinned*: they compare
/// against artefacts or thresholds captured on one specific Mac, so a different renderer
/// or a different CPU fails them for machine reasons rather than code reasons. Marking the
/// reason (rather than encoding it in the type's name) is deliberate: the gap this replaced
/// existed because `--skip SnapshotTests` selected by name, so `AccentPreviewTests` — every
/// bit as machine-pinned — was silently never skipped.
enum MachinePinnedReason: String {
    /// Compares rendered output against reference PNGs recorded on one Mac.
    case referenceImages
    /// Reads painted pixels back out of a live renderer (`colorAt(`).
    case pixelSampling
    /// Asserts latency thresholds calibrated on this hardware.
    case calibratedTiming
    /// Reads the developer's **live** filing profile and real document tree.
    ///
    /// Pinned for two separate reasons, and the second is the one that bit. It is *semantically*
    /// local — the assertions are about one person's 3,013-folder corpus, which exists on exactly
    /// one machine, so anywhere else the suite either skips or asserts about nothing. And it is
    /// *expensive*: the CI runner is this same Mac running osx-x64 under Rosetta, where the same
    /// walk measured **10.8s against 1.05s natively**. Because swift-testing runs suites in
    /// parallel, that cost is not paid alone — it starves whatever timing-sensitive tests happen to
    /// be running beside it, which is how a green local run became three CI failures in
    /// `ScanSupersedenceTests` and `DifferenceResolutionTests` that had nothing to do with the
    /// change.
    ///
    /// An `.enabled(if:)` on the profile's existence is NOT enough on its own: the runner runs as
    /// the same user, so the profile is right there and the suite runs in full.
    case liveProfile
}

enum MachinePinnedGate {

    /// Reasons excluded by `SYNCCLOUD_SKIP_MACHINE_PINNED`, which takes `all` or a
    /// comma-separated list (`referenceImages,pixelSampling`). Unset — the local default,
    /// and the one that matters most — runs everything, so a developer on the recording
    /// machine never has to know this exists.
    static let excludedReasons: Set<String> = {
        let raw = ProcessInfo.processInfo.environment["SYNCCLOUD_SKIP_MACHINE_PINNED"] ?? ""
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }()

    static func isExcluded(_ reason: MachinePinnedReason) -> Bool {
        excludedReasons.contains("all") || excludedReasons.contains(reason.rawValue.lowercased())
    }

    /// The message a skipped suite reports, so a reader of CI output learns why it did not run.
    static func comment(_ reason: MachinePinnedReason) -> Comment {
        "machine-pinned (\(reason.rawValue)) — excluded via SYNCCLOUD_SKIP_MACHINE_PINNED"
    }
}

extension Trait where Self == ConditionTrait {

    /// Marks a suite as pinned to the recording machine, and skips it when CI says to.
    ///
    /// Applied at the declaration — next to the code that does the pixel reading — so adding
    /// a new pinned suite is a one-token change that cannot be forgotten by a renamer.
    static func machinePinned(_ reason: MachinePinnedReason) -> Self {
        .disabled(if: MachinePinnedGate.isExcluded(reason), MachinePinnedGate.comment(reason))
    }
}
