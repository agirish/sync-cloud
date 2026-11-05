import Foundation
import Testing

// NOTE: Duplicated in the other five test targets, because SPM can't share test-support code
// across packages without a production library product. Change the copies too:
//   Modules/FileExplorer/Tests/FileExplorer/MachinePinned.swift
//   Modules/Design/Tests/DesignTests/MachinePinned.swift
//   Modules/Settings/Tests/Settings/MachinePinned.swift
//   Modules/Sync/Tests/Sync/MachinePinned.swift
//   SyncCloudTests/MachinePinned.swift

/// Why a suite only gives a trustworthy verdict on the machine that recorded it. Pinned suites
/// compare against artefacts or thresholds captured on one Mac, so another renderer or CPU fails
/// them for machine reasons, not code reasons. The reason is a trait rather than part of the type's
/// name, so a skip can't miss a pinned suite whose name doesn't match.
enum MachinePinnedReason: String {
    /// Compares rendered output against reference PNGs recorded on one Mac.
    case referenceImages
    /// Reads painted pixels back out of a live renderer (`colorAt(`).
    case pixelSampling
    /// Asserts latency thresholds calibrated on this hardware.
    case calibratedTiming
    /// Measures laid-out text and control geometry (`fittingSize`, intrinsic widths, wrap points),
    /// which follows the OS's fonts and metrics and so differs across macOS releases and displays.
    case layoutMetrics
    /// Recognises text with Vision. On GitHub's hosted macOS VMs `VNRecognizeTextRequest` fails
    /// with `nilError`, so the verdict there says nothing about the code.
    case textRecognition
    /// Turns speech into text with SpeechAnalyzer, which needs its 379 MB speech model on the Mac.
    /// A hosted CI VM doesn't have it and would download it first.
    case speechRecognition
    /// Needs a real iCloud Drive folder (`~/Library/Mobile Documents/com~apple~CloudDocs`), which
    /// exists only where an Apple Account is signed in — never on a hosted CI VM.
    case iCloudDrive
    /// Reads the developer's live filing profile and real document tree. Pinned for two reasons:
    /// the assertions are about one person's corpus, which exists on one machine; and the walk is
    /// slow under Rosetta on the CI runner, and since suites run in parallel it starves the
    /// timing-sensitive tests beside it.
    ///
    /// An `.enabled(if:)` on the profile's existence is not enough: the runner runs as the same
    /// user, so the profile is there and the suite runs in full.
    case liveProfile
}

enum MachinePinnedGate {

    /// Reasons excluded by `SYNCCLOUD_SKIP_MACHINE_PINNED`, which takes `all` or a comma-separated
    /// list (`referenceImages,pixelSampling`). Unset, the local default, runs everything.
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

    /// Marks a suite as pinned to the recording machine, and skips it when CI says to. Applied at
    /// the declaration, so marking a new suite is one token and survives a rename.
    static func machinePinned(_ reason: MachinePinnedReason) -> Self {
        .disabled(if: MachinePinnedGate.isExcluded(reason), MachinePinnedGate.comment(reason))
    }
}
