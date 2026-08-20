import Events
import Foundation
import ServiceManagement
import SwiftUI
import Sync
import Design
import UserNotifications

/// UserDefaults keys for General settings that are read outside the Settings module — the app
/// delegate's quit guard and ContentView's launch-time seeding both reference the same literals,
/// so they live here as the single source of truth.
public enum GeneralSettings {
    /// Bool (default true). When false, the app quits immediately even with file operations in flight.
    public static let warnBeforeQuitKey = "warnBeforeQuitDuringOperations"
    /// Bool (default false). Seeds `FileSyncManager.showHiddenFiles` at launch.
    public static let showHiddenByDefaultKey = "showHiddenFilesByDefault"
    /// Bool (default true). When false, Delete acts immediately — items still go to the Trash
    /// and remain undoable. Read by `FileActionHandler.confirmDelete`.
    public static let confirmBeforeDeleteKey = "confirmBeforeDelete"
    /// Bool (default true). When false, copies and moves start immediately without the
    /// what-goes-where confirmation. Read by the app's `transferConfirmer` wiring.
    public static let confirmBeforeTransferKey = "confirmBeforeCopyMove"

    /// Bool (default true). When false, panes always open at their provider roots instead of
    /// the folders they were focused on when the app last quit.
    public static let restoreLastFocusKey = "restoreLastFocusOnLaunch"
    /// String. The left pane's root-relative focus path, continuously persisted by
    /// ContentView ("" = provider root). App state rather than a user preference, but the
    /// keys live here beside the toggle that governs them.
    public static let lastLeftFocusKey = "lastLeftFocusPath"
    /// Right-pane counterpart of `lastLeftFocusKey`.
    public static let lastRightFocusKey = "lastRightFocusPath"

    /// Bool (default false). Posts a system notification when an operation banner lands
    /// while SyncCloud is not the active app. Read by `OperationNotifier`.
    public static let notifyOnBackgroundCompletionKey = "notifyOnBackgroundCompletion"

    /// String (default "TODO"). The provider-root-relative folder where loose files pile up.
    ///
    /// **It names a folder; it no longer moves anything.** This used to be read in two places, and
    /// the second one was the complaint: `ContentView.tidyRailRelativePath(for:)` opened Organize's
    /// source rail on this folder, so a fresh install — where the key is unset and this default
    /// applies — jumped the rail into `TODO` on the first switch to Organize. That is gone. What
    /// reads it now is `ContentView.filingInboxFolder`, which resolves the path for Organize's
    /// overview to offer as a one-click scope.
    ///
    /// **Empty is a real value and means "no offer".** The Settings field shows `None` as its
    /// placeholder rather than this default, so an emptied field cannot be mistaken for an
    /// untouched one.
    public static let filingInboxRelativePathKey = "filingInboxRelativePath"

    /// The delete-confirmation flag with its default-true semantics (a bare `bool(forKey:)`
    /// would read an unset key as false and silently skip the alert).
    public static func shouldConfirmBeforeDelete(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: confirmBeforeDeleteKey) as? Bool) ?? true
    }

    /// The copy/move-confirmation flag with the same default-true semantics.
    public static func shouldConfirmBeforeTransfer(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: confirmBeforeTransferKey) as? Bool) ?? true
    }

    /// The restore-last-focus flag with its default-true semantics.
    public static func shouldRestoreLastFocus(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: restoreLastFocusKey) as? Bool) ?? true
    }
}

/// The app's settings window, hosted in the SwiftUI `Settings` scene. Follows the standard
/// macOS preferences layout: toolbar tabs (Appearance / Providers / Sync) over grouped forms.
public struct SettingsView: View {
    /// Identifies a settings tab; raw values are the format of the `settingsSelectedTab`
    /// default read at window creation, so treat them as stable. `CaseIterable` backs both the
    /// segmented picker and the search index's "every entry points at a real tab" invariant.
    /// The rail's rows, in rail order.
    ///
    /// `people` and `intelligence` are NEW CASES rather than renames of `filing`, and the
    /// distinction matters. `providers` → "Sources" was a relabel: the same tab, reworded, so the
    /// case kept its name and every stored `settingsSelectedTab` stayed valid. This is not that.
    /// The household roster and the AI engine were *sections* of Organize that became tabs of
    /// their own, so `filing` still exists and still means Organize — it is simply three sections
    /// lighter. Renaming it would have made every stored "filing" resolve to a tab that no longer
    /// holds what the user was last looking at.
    ///
    /// Adding cases is safe in the other direction too: the stored value is resolved through
    /// `resolvingStored(_:)`, which falls back rather than trapping, so a build that predates
    /// these two resolves their raw values to **Appearance** — the tab that depends on nothing.
    /// `StoredTabResolutionTests` is what checks that; this paragraph previously named the wrong
    /// tab and cited a test that did not exist, which is the reason the seam is there at all.
    public enum SettingsTab: String, CaseIterable, Sendable {
        case general
        case appearance
        case providers
        /// The household the filing rules attribute documents to. Was Organize's last section.
        case people
        case sync
        /// Shown as "Organize". The case is named for `Workspace.filing`, not for the label, for
        /// the reason that workspace keeps its own name: the label moved and the identity didn't,
        /// and a tab whose case matches its workspace's is one grep away from the code it governs.
        case filing
        case duplicates
        /// The suggestion engine — on-device AI, the opt-in Claude path, and what that path costs.
        case intelligence
        case advanced

        /// The human-readable tab name shown in the rail and as the dim subtitle on a search
        /// result. Kept here so the labels have a single source of truth.
        public var displayName: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            // "Sources", not "Providers": the tab lists plain folders alongside the cloud accounts
            // now, and a folder is not a provider — "Discovered providers" over a row saying
            // ~/Projects was the tell. The case keeps its name so the stable `settingsSelectedTab`
            // raw value, and every `selectedTab = .providers` deep link, are untouched.
            case .providers: return "Sources"
            case .people: return "People"
            case .sync: return "Sync"
            case .filing: return "Organize"
            case .duplicates: return "Duplicates"
            // Not "Claude" and not "AI & Cloud": the tab holds the free on-device pass as well as
            // the paid one, so a vendor name would sit over a section that isn't theirs, and
            // "Cloud" collides with Sources' cloud providers — a rail with two Clouds in it
            // answers the wrong question first. The search index is what carries "API key" and
            // "Anthropic" to this tab; see `SettingsSearchIndex`.
            case .intelligence: return "Intelligence"
            case .advanced: return "Advanced"
            }
        }

        /// The rail row's SF Symbol. Monochrome and outline-weight throughout: a rail of mixed
        /// filled and outline glyphs reads as though the filled ones meant something.
        ///
        /// Organize and Duplicates take the glyphs their workspaces wear in the bar
        /// (`Workspace.symbol`) rather than picking settings-only ones — the rail row and the bar
        /// button are two ways into the same feature, and a second glyph for it would say they
        /// weren't.
        public var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .providers: return "cloud"
            case .people: return "person.2"
            case .sync: return "arrow.left.arrow.right"
            case .filing: return "folder.badge.gearshape"
            case .duplicates: return "doc.on.doc"
            case .intelligence: return "sparkles"
            case .advanced: return "wrench.and.screwdriver"
            }
        }

        /// Where the "set up cloud refine" offer on Organize's results deep-links to: the tab that
        /// holds the Claude toggle, the key and the model.
        ///
        /// A named destination rather than `.intelligence` written at the call site, because the
        /// call site is in `MacApp/` — which belongs to no SPM package, so only the app target
        /// compiles it and no package test can reach it. A literal there that pointed at the tab
        /// those controls used to live on would keep compiling and keep opening Settings; it would
        /// simply open a tab with no cloud anything on it, and nothing would fail. This constant
        /// is the seam that lets `theCloudRefineOfferLandsOnTheTabThatHoldsTheKey` check it.
        public static let cloudRefineSetup: SettingsTab = .intelligence

        /// The tabs the layout fit-guard (`SettingsLayoutTests`) deliberately does NOT hold to
        /// "lays out inside the sheet's opening without scrolling". Every other tab is measured;
        /// `everyTabIsEitherFitTestedOrExplicitlyExempt` derives the measured list from `allCases`
        /// minus this set, so a new case cannot skip the guard silently — it either joins the
        /// fit list or earns a line here.
        ///
        /// Membership is a *property of the tab*, not an oversight, and each entry records its
        /// reason:
        /// - `providers` grows with the Mac's provider and folder-source lists — its height is a
        ///   property of the machine's data, and its own header comment calls it "the one that
        ///   legitimately keeps scrolling".
        /// - `people` grows with the household roster (`PeopleList` draws one row per person),
        ///   so its height is the user's data too.
        /// - `filing` grows with the kept-names list (`KeptNamesList` draws one row per kept
        ///   name) — the same shape as `people`, down to the `if let store … else` fixed note,
        ///   and now on the same side of the guard.
        /// - `intelligence` is long by nature — four sections, from the on-device toggles to the
        ///   saved suggestions — and is expected to scroll;
        ///   `intelligenceLaysOutWithoutReachingForTheKeychain` pins that it lays out at all.
        ///
        /// **`filing` was fit-tested until 2026-08-13, and that guard was measuring the wrong
        /// view.** Its fixture built the tab with no engine (`FilingSettingsTab(syncManager: nil)`),
        /// which takes the `else` branch and renders `KeptNamesList.nothingKeptNote` — one line.
        /// So the guard proved the EMPTY tab fits while a real user scrolled: measured against a
        /// 1280×800 display's 647pt opening, the tab is 280pt with nothing kept and grows 23pt a
        /// row, so it passes the opening at the **17th** kept name (16 names = 638pt, 17 = 661pt).
        /// The lesson generalises past this tab: **a fit-guard fixture built with a nil dependency
        /// measures the empty state**, so a tab whose list is unbounded belongs here no matter how
        /// well its `else` branch fits.
        ///
        /// An exemption is a measured claim, not a label. Each entry above is held to it by a test
        /// that fails if the tab stops being long — `intelligenceLaysOutWithoutReachingForTheKeychain`
        /// for `intelligence`, `theOrganizeTabOutgrowsItsOpeningOnceNamesAreKept` for `filing` —
        /// and the coverage the fit guard used to give Organize is kept, narrowed to what it
        /// actually measured, by `theOrganizeTabFitsItsOpeningWithNothingKept`. A data-driven tab
        /// that gains a bounded list, or a long tab that loses a section, should have its exemption
        /// revisited rather than inherited: Organize kept a stale "long by nature" exemption through
        /// the split that made it short, and no test asked again until it was re-measured by hand.
        /// (`providers` and `people` carry no such falsifying measurement yet.)
        public static let exemptFromFitGuard: Set<SettingsTab> = [.providers, .people, .filing, .intelligence]

        /// The rail's rows in groups, separated by a hairline.
        ///
        /// Nine flat rows read as a pile — the reason this exists — but the grouping is not free:
        /// the rail is FIXED-HEIGHT and does not scroll, and each separator costs its own line
        /// plus the air around it. `theRailFitsItsOpening` measures the real thing, separators
        /// included, so a group added here has to be paid for out of the same budget the rows are.
        ///
        /// The cut lines are by *question asked*, not by feature: the app itself, then the nouns
        /// in the user's world, then what a scan does, then the engine room. Membership is spelled
        /// out rather than derived so that adding a case has to state which group it joins —
        /// `railGroupsCoverEveryTab` fails on a case that names none.
        public static let railGroups: [[SettingsTab]] = [
            [.general, .appearance],
            [.providers, .people],
            [.sync, .filing, .duplicates],
            [.intelligence, .advanced],
        ]
    }

    /// UserDefaults key holding the tab the Settings overlay opens on (a `SettingsTab` raw
    /// value). ContentView reads it once at launch to honor the GUI-verification recipe, which
    /// writes it via `defaults`; the literal is a stable format.
    public static let selectedTabDefaultsKey = "settingsSelectedTab"

    /// Selected tab, owned by the host (ContentView) so it survives an overlay open/close cycle
    /// and can be preset — e.g. the invalid-pane fix-it action opens straight to Providers.
    @Binding private var selectedTab: SettingsTab

    /// Dismisses the overlay. Invoked by the ✕ button and the Escape shortcut; the host also
    /// dismisses on a click outside the card.
    private let onClose: () -> Void

    /// The app's sync engine, for the settings that read or act on live engine state (the
    /// ignored-items list, the orphan sweep). Optional so previews and hosts without an
    /// engine still render; the dependent controls hide when nil.
    private let syncManager: FileSyncManager?

    /// Runs the full settings reset (defaults wipe plus the host's re-seeding of live state).
    /// Provided by the host; the Reset control hides when nil.
    private let onResetAllSettings: (() -> Void)?

    /// The header search text. While non-empty it takes over the content area with a list of
    /// matching settings across every tab; selecting one jumps to its tab and clears this.
    @State private var searchQuery = ""

    /// Whether the search field currently has meaningful (non-whitespace) input. Drives the
    /// swap between the normal tab content and the search results.
    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Entries matching the current query, in index order. Empty while the field is empty.
    private var searchResults: [SettingsSearchEntry] {
        filterSettings(SettingsSearchIndex.all, query: searchQuery)
    }

    /// The window's accent hue, for the rail's selected row. Read here rather than passed in so
    /// the sheet keeps tracking the hue while the user changes it on the Appearance tab.
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlassHue.blue.rawValue
    private var selectedHue: LiquidGlassHue { LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue }

    /// The app's text-size setting. The sheet is sized in points but its contents are sized in
    /// scaled type, so the sheet has to grow with the type or the taller tabs start scrolling
    /// again at Large — the exact failure this layout exists to fix.
    @AppStorage(FontSize.defaultsKey) private var fontSizePercent: Int = FontSize.medium.percent
    private var fontSize: FontSize { FontSize(percent: fontSizePercent) }

    /// The space the host has to place the sheet in, or `nil` when the host doesn't say. The
    /// window's own minimum is 760×560, which after `hostMargin` is still less than the sheet
    /// wants at any text size, so without this the sheet would hang off the edge of a small
    /// window.
    private let availableSize: CGSize?

    public init(
        selection: Binding<SettingsTab>,
        onClose: @escaping () -> Void,
        syncManager: FileSyncManager? = nil,
        onResetAllSettings: (() -> Void)? = nil,
        availableSize: CGSize? = nil
    ) {
        _selectedTab = selection
        self.onClose = onClose
        self.syncManager = syncManager
        self.onResetAllSettings = onResetAllSettings
        self.availableSize = availableSize
    }

    /// The sheet's size: see `SettingsSheetMetrics`, which owns the arithmetic.
    private var sheetSize: CGSize {
        SettingsSheetMetrics.resolvedSize(textScale: fontSize.scale, available: availableSize)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .scaledFont(.headline)
                Spacer()
                CloseButton(action: onClose)
                    // Escape closes the overlay even when focus is elsewhere in the card.
                    .keyboardShortcut(.cancelAction)
                    .shortcutKeycap("esc")
                    .help(ShortcutHint.tooltip("Close settings", "esc"))
            }
            .padding(.horizontal, 16)
            // Fixed rather than padding-derived: the content opening below is computed as
            // `height − headerHeight − 1`, and a header that sized itself would make that
            // arithmetic — and every layout assertion resting on it — a guess.
            .frame(height: SettingsSheetMetrics.headerHeight * fontSize.scale)

            Divider()

            HStack(spacing: 0) {
                // Search and the tabs stand down the left — the macOS Settings convention, and
                // the reason the content column gets its height back. Both used to be rows
                // stacked above the content, costing 124pt before the first control.
                SettingsRail(selection: $selectedTab, query: $searchQuery, hue: selectedHue)
                    .background(Color.primary.opacity(0.035))

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
    }

    /// The right-hand column: the selected tab, or the search results standing in for it.
    @ViewBuilder
    private var content: some View {
        if isSearching {
            SettingsSearchResults(results: searchResults) { tab in
                // The jump: land on the matching tab and drop back to normal content.
                selectedTab = tab
                searchQuery = ""
            }
        } else {
            switch selectedTab {
            case .general:
                GeneralSettingsTab()
            case .appearance:
                AppearanceSettingsTab()
            case .providers:
                ProvidersSettingsTab()
            case .people:
                PeopleSettingsTab(syncManager: syncManager)
            case .sync:
                SyncSettingsTab(syncManager: syncManager)
            case .filing:
                FilingSettingsTab(syncManager: syncManager)
            case .duplicates:
                DuplicatesSettingsTab()
            case .intelligence:
                IntelligenceSettingsTab(syncManager: syncManager)
            case .advanced:
                AdvancedSettingsTab(syncManager: syncManager, onResetAllSettings: onResetAllSettings)
            }
        }
    }
}

// MARK: - Settings search

/// One searchable settings control: the tab it lives on, its display title, and a few
/// synonyms/keywords so a search for "blur" finds "Glass effect" and "trash" finds the
/// delete confirmation. Pure data with a pure match — no SwiftUI — so the filter is unit-testable.
struct SettingsSearchEntry: Identifiable, Sendable {
    let tab: SettingsView.SettingsTab
    let title: String
    let keywords: [String]

    /// Stable across renders: a title is unique within its tab, and tabs are distinct.
    var id: String { "\(tab.rawValue).\(title)" }

    /// Case-insensitive substring match against the title or any keyword. The query is trimmed,
    /// and an empty query never matches — the results stay hidden until the user types something.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        if title.lowercased().contains(needle) { return true }
        return keywords.contains { $0.lowercased().contains(needle) }
    }
}

/// The catalog of settings the header search can jump to: one entry per control that *changes*
/// something, across every tab. One kind of on-screen label deliberately gets no entry of its own,
/// because it is not a setting: the `SettingsSection` headers that only group other controls
/// ("Conflicts", "Logging", "Inbox and rules"). Each is reached through a control it belongs to.
///
/// It used to say "and the read-only readouts in Organize's Cloud spend section" as well. Those
/// four rows are gone — `FilingSpendReadout` draws the figures now, and the section is Cost and
/// limits on Intelligence — so the sentence described neither a tab nor a control that exists.
///
/// Titles mirror the on-screen label, or extend it where the label alone would be ambiguous in a
/// results list that shows nothing but the title and its tab ("Surface tint" for the section
/// headed "Tint"). Keywords add the words people are likely to type instead — synonyms, the value
/// names, the feature they're after.
///
/// This is the single place to keep in sync when a control is added or renamed, and
/// `SettingsSearchTests.everyControlLabelInTheTabSourcesIsIndexed` holds that: it scans the tab
/// sources for control labels and fails on one that reaches nothing here. A control whose label
/// the scan cannot see (a title built at runtime, a control vehicle it does not model) is still
/// only as indexed as whoever adds it makes it.
enum SettingsSearchIndex {
    static let all: [SettingsSearchEntry] = [
        // General
        .init(tab: .general, title: "Launch SyncCloud at login",
              keywords: ["launch", "login", "startup", "start", "open at login", "boot", "auto start"]),
        .init(tab: .general, title: "Show hidden files by default",
              keywords: ["hidden", "dotfiles", "invisible", "show hidden"]),
        .init(tab: .general, title: "Reopen panes where I left off",
              keywords: ["restore", "reopen", "last focus", "remember folders", "panes", "resume"]),
        .init(tab: .general, title: "Sort panes by",
              keywords: ["sort", "order", "sorting", "name", "size", "date", "default sort"]),
        .init(tab: .general, title: "Notify when operations finish in the background",
              keywords: ["notification", "notify", "background", "alert", "banner", "system notification"]),
        .init(tab: .general, title: "Warn before quitting during file operations",
              keywords: ["quit", "warn", "confirm quit", "close", "exit"]),

        // Appearance
        // "theme" lives here, not on Accent color: since the Theme control exists, that word
        // means light/dark to users, and matching it on the accent row steered them wrong.
        .init(tab: .appearance, title: "Theme",
              keywords: ["theme", "light", "dark", "dark mode", "light mode", "appearance",
                         "system", "night", "follow macos"]),
        .init(tab: .appearance, title: "Accent color",
              keywords: ["accent", "color", "colour", "hue", "highlight"]),
        .init(tab: .appearance, title: "Glass effect",
              keywords: ["glass", "translucency", "transparency", "frosted", "clear", "solid",
                         "blur", "liquid glass", "material", "opaque", "see-through"]),
        .init(tab: .appearance, title: "Surface tint",
              keywords: ["tint", "wash", "color overlay", "vivid", "subtle"]),
        // "solid" belongs to Glass effect now, not here: this control is shape only.
        .init(tab: .appearance, title: "Content surface style",
              keywords: ["surface", "unified", "cards", "pane background", "content surface"]),
        // Three entries for one section: the group heading a search for "spacing" should land on,
        // and the two controls inside it, which people look for by their own names. "List density"
        // keeps its keywords even though the label now reads Row spacing — the word was on screen
        // for four releases and searching for it must still find the control it named.
        .init(tab: .appearance, title: "Size & spacing",
              keywords: ["size", "spacing", "size and spacing", "preset", "presets", "scale",
                         "zoom", "how much fits", "bigger", "smaller"]),
        .init(tab: .appearance, title: "Text size",
              keywords: ["text size", "font", "font size", "type size", "bigger text", "larger text",
                         "smaller text", "readability", "zoom", "scale", "percent", "percentage"]),
        .init(tab: .appearance, title: "Row spacing",
              keywords: ["density", "list density", "compact", "comfortable", "row height",
                         "spacing", "row spacing", "tighter rows", "row size"]),

        // Sources
        .init(tab: .providers, title: "Cloud providers",
              keywords: ["providers", "cloud", "discover", "refresh", "cloudstorage", "sources",
                         "icloud", "dropbox", "onedrive", "google drive"]),
        .init(tab: .providers, title: "Local folders",
              keywords: ["folder", "local", "add folder", "choose folder", "mac", "home folder",
                         "volume", "disk", "external drive", "source", "remove folder"]),
        .init(tab: .providers, title: "Check folder names against",
              keywords: ["names", "risky names", "rename", "name rules", "onedrive rules",
                         "reserved", "check names", "folder names"]),
        .init(tab: .providers, title: "Source name",
              keywords: ["rename", "name", "provider name", "custom name", "label"]),
        .init(tab: .providers, title: "Synchronized path",
              keywords: ["path", "location", "root", "folder", "directory", "sync path", "browse"]),
        .init(tab: .providers, title: "Enable or disable a source",
              keywords: ["enable", "disable", "show", "hide", "sidebar", "toggle provider",
                         "toggle source"]),

        // People. Indexed by what it is *about* as much as by its label: someone looking for this
        // is more likely to type a relationship or the thing it prevents ("wrong person") than
        // "people". "organize" and "filing" stay on it because the roster was a section of that
        // tab until this split, and someone who remembers where it was will look there first.
        .init(tab: .people, title: "People",
              keywords: ["people", "person", "family", "household", "names", "full name",
                         "wife", "husband", "son", "daughter", "mother", "father", "kids",
                         "wrong person", "whose document", "who", "aliases", "privacy",
                         "what is stored", "data", "organize", "filing"]),
        // The Add button is its own entry: "add person" is what someone types when the roster is
        // missing somebody, and it would otherwise reach nothing — the section title does not
        // contain the word they used.
        .init(tab: .people, title: "Add Person…",
              keywords: ["add person", "new person", "add family member", "add someone",
                         "remove person", "delete person", "edit person", "rename person",
                         "relationship", "brother", "sister", "roster"]),

        // Sync
        .init(tab: .sync, title: "When a file already exists",
              keywords: ["conflict", "conflict policy", "overwrite", "replace", "keep both", "duplicate handling"]),
        .init(tab: .sync, title: "Treat dates as equal within",
              keywords: ["date tolerance", "date", "timestamp", "tolerance", "modified date", "rounding"]),
        .init(tab: .sync, title: "Verify same-size files during scans",
              keywords: ["verify", "checksum", "same size", "scan verification", "hash"]),
        .init(tab: .sync, title: "Ignore \"newer on Google Drive\" when same size",
              keywords: ["google drive", "newer", "ignore date", "gdrive"]),
        .init(tab: .sync, title: "Confirm before copying or moving",
              keywords: ["confirm copy", "confirm move", "transfer confirmation", "what goes where", "confirm before copy"]),
        .init(tab: .sync, title: "Confirm before deleting",
              keywords: ["confirm delete", "delete confirmation", "trash", "remove"]),
        .init(tab: .sync, title: "Remember ignored items across rescans",
              keywords: ["ignored items", "remember ignores", "hidden differences", "ignore"]),
        .init(tab: .sync, title: "Ignored name patterns",
              keywords: ["ignore patterns", "glob", "exclude", "wildcard", "ds_store", "node_modules", "patterns"]),

        // Organize — what is left of it after the engine moved to Intelligence and the roster
        // to People: the two settings that describe the JOB rather than the machinery.
        // "tidy" is kept as a keyword on the entries a Tidy-era user is most likely to hunt for
        // by that name: the word left the product with that split, so someone who remembers it
        // has nothing to type otherwise. "filing" is kept the same way: the section header over
        // the inbox said "Filing" until it was renamed to "Inbox and rules", so it is the word
        // a Filing-era user types.
        //
        // "loose files" and "todo" are the two a user actually types: the title spells the first
        // hyphenated ("Loose-files"), so the spaced form matches nothing without the keyword, and
        // the second is the default value rather than anything in the label.
        .init(tab: .filing, title: "Loose-files inbox",
              keywords: ["inbox", "loose files", "todo", "default folder", "scan folder",
                         "organize", "tidy", "filing"]),
        .init(tab: .filing, title: "Remembered rules",
              keywords: ["filing rules", "rules", "remembered rules", "manage rules", "automation", "automations"]),
        // Nearly every query for this one misses the label. The section is titled "Kept names",
        // but the decision is made from a menu item worded "Always Allow This Name" and withdrawn
        // from one worded "Stop Allowing This Name" — so "allow" is the word the user has actually
        // read — and what they are looking for is more likely described by the problem ("risky
        // name", "trailing space", "badge") than by the state they put it in.
        .init(tab: .filing, title: "Kept names",
              keywords: ["kept name", "keep name", "allow name", "always allow", "stop allowing",
                         "allowed names", "risky name", "risky names", "badge", "name badge",
                         "trailing space", "forbidden character", "rename", "exceptions"]),

        // Duplicates
        .init(tab: .duplicates, title: "Ignore files smaller than",
              keywords: ["minimum size", "min file size", "small files", "duplicates", "threshold size", "tidy"]),
        .init(tab: .duplicates, title: "Folders overlap at",
              keywords: ["overlap", "threshold", "folder overlap", "percent", "duplicates"]),
        .init(tab: .duplicates, title: "Detect versions",
              keywords: ["versions", "final", "copy", "report (1)", "variants", "duplicates"]),
        // Nobody hunting for this types its label. They type what they were doing when they
        // noticed it: the same bill downloaded twice, or the minutes the first scan took.
        .init(tab: .duplicates, title: "Read PDFs to find copies a byte hash misses",
              keywords: ["pdf", "text", "same text", "content", "fingerprint", "re-downloaded",
                         "downloaded twice", "re-stamped", "slow scan", "duplicates"]),

        // Intelligence — the engine and its cost, in tab order. This block carries more of the
        // findability load than any other: the rail says "Intelligence", and nobody hunting for
        // where their API key goes types that word. Every entry keeps the "organize"/"filing"
        // keywords it had before the split for the same reason the People block does.
        .init(tab: .intelligence, title: "Suggest folders with on-device AI",
              keywords: ["filing", "apple intelligence", "on-device ai", "suggestions", "suggest folders",
                         "sort files", "organize", "tidy", "intelligence"]),
        .init(tab: .intelligence, title: "Read file contents on-device for better signals",
              keywords: ["read contents", "content signals", "ocr", "text", "pdf", "vision"]),
        // "refine" is the word on the button this row enables, and the one someone who has seen
        // that button will type; "best suggestions" is what the row used to be called.
        .init(tab: .intelligence, title: "Use Claude (cloud) to refine suggestions",
              keywords: ["claude", "cloud", "anthropic", "cloud filing", "ai", "refine",
                         "best suggestions", "organize"]),
        // "claude" belongs on the KEY, not only on the toggle above it. The title says Anthropic
        // and the product says Claude, and someone pasting an `sk-ant-…` types whichever of the
        // two they last read — which for anyone coming from the Console or the Refine button is
        // "claude api key".
        .init(tab: .intelligence, title: "Anthropic API key",
              keywords: ["api key", "key", "keychain", "sk-ant", "anthropic key", "token",
                         "api", "credentials", "secret", "claude", "claude key", "claude api key"]),
        .init(tab: .intelligence, title: "Cloud model",
              keywords: ["model", "haiku", "sonnet", "opus", "claude model"]),
        // Titled for the section it now sits in ("Cost and limits"); "cloud spend" stays as a
        // keyword because that is what the section was called and what the history sheet says.
        .init(tab: .intelligence, title: "Cost and limits",
              keywords: ["spend", "cloud spend", "cost", "tokens", "billing", "usage", "money", "price"]),
        .init(tab: .intelligence, title: "Monthly budget cap",
              keywords: ["budget", "cap", "limit", "monthly", "spend limit", "cost cap", "guardrail", "pause cloud", "money"]),
        .init(tab: .intelligence, title: "Total budget cap",
              keywords: ["budget", "cap", "limit", "total", "lifetime", "spend limit", "cost cap", "guardrail", "pause cloud", "money", "backstop"]),
        // "cache" is the word an engineer reaches for and the UI deliberately never says, so it
        // has to live here or the row is unfindable by the people most likely to look for it.
        .init(tab: .intelligence, title: "Reuse suggestions for files that haven’t changed",
              keywords: ["reuse", "cache", "cached suggestions", "rescan", "re-ask", "cost", "save money"]),
        .init(tab: .intelligence, title: "Saved suggestions",
              keywords: ["saved suggestions", "clear cache", "cache", "forget suggestions", "reset suggestions"]),

        // Advanced
        .init(tab: .advanced, title: "Log level",
              keywords: ["log", "logging", "debug", "verbosity", "log level", "info", "warnings", "errors"]),
        .init(tab: .advanced, title: "Log file",
              keywords: ["log file", "logs", "clear log", "show log"]),
        .init(tab: .advanced, title: "Sweep orphaned temporary files",
              keywords: ["orphan", "temp files", "tmp", "sweep", "maintenance", "cleanup", "clean up"]),
        .init(tab: .advanced, title: "File digests",
              keywords: ["digests", "checksums", "hashes", "content hash", "cache", "disk space",
                         "storage", "saved scan data", "duplicates", "verify"]),
        .init(tab: .advanced, title: "Saved Storage reports",
              keywords: ["storage lens", "saved reports", "snapshots", "cache", "disk space",
                         "saved scan data"]),
        .init(tab: .advanced, title: "Reset all settings",
              keywords: ["reset", "defaults", "restore defaults", "factory reset", "wipe"]),
    ]
}

/// Filters the search index for a query. Case-insensitive, whitespace-trimmed, matching the
/// title or any keyword; an empty (or whitespace-only) query returns nothing so the results
/// list stays hidden until the user types. Pure and free-standing for unit testing.
func filterSettings(_ entries: [SettingsSearchEntry], query: String) -> [SettingsSearchEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return entries.filter { $0.matches(trimmed) }
}

/// The search results that stand in for the tab content while the field has text: a scrollable
/// list of matching settings, each showing its title and — dimmed — the tab it lives on. A tap
/// hands the tab back to `SettingsView` for the jump. An empty result set shows a gentle miss.
private struct SettingsSearchResults: View {
    let results: [SettingsSearchEntry]
    let onSelect: (SettingsView.SettingsTab) -> Void

    var body: some View {
        if results.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No settings match your search.",
                layout: .compact
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { entry in
                        Button {
                            onSelect(entry.tab)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .foregroundStyle(.primary)
                                    Text(entry.tab.displayName)
                                        .scaledFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                HoverChevron()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverAffordance(.row))
                        Divider().padding(.leading, 16)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - General

/// App-level preferences: login item, startup state (hidden files, last folders, sort),
/// background notifications, and the quit safety guard.
struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsManager
    /// Mirrors `SMAppService.mainApp.status`. Deliberately not seeded in the initializer:
    /// the status getter is a synchronous XPC call, which must not run on the main thread —
    /// `.task` kicks off a detached read once the view is up (and app activation re-reads,
    /// since approval happens over in System Settings).
    @State private var launchAtLogin = false
    /// The login item is registered but awaits the user's consent in System Settings →
    /// Login Items; shown distinctly so a pending approval doesn't read as a broken toggle.
    @State private var loginItemNeedsApproval = false
    /// Tells a user's flip apart from the echo of a programmatic set, keeps the register /
    /// unregister calls serialised to one at a time, and decides what a finished round-trip
    /// owes the user — see `LoginItemEchoGuard`, where the whole state machine lives so it can
    /// be tested without an SMAppService round-trip.
    @State private var loginItemEcho = LoginItemEchoGuard()
    @AppStorage(GeneralSettings.showHiddenByDefaultKey) private var showHiddenByDefault: Bool = false
    @AppStorage(GeneralSettings.warnBeforeQuitKey) private var warnBeforeQuit: Bool = true
    @AppStorage(GeneralSettings.restoreLastFocusKey) private var restoreLastFocus: Bool = true
    @AppStorage(GeneralSettings.notifyOnBackgroundCompletionKey) private var notifyInBackground: Bool = false
    /// Whether the system has DENIED notification permission while the toggle is on — the one
    /// state where the feature looks enabled here but can never fire. Surfaced in the footer
    /// (mirroring the login-item "Approval needed" hint) and re-checked on toggle and app
    /// re-activation, since the user flips the real switch over in System Settings.
    @State private var notificationsDenied = false

    var body: some View {
        SettingsPage {
            SettingsSection {
                Toggle("Launch SyncCloud at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard loginItemEcho.shouldStartRoundTrip(for: enabled, at: .now) else {
                            // Echo of a programmatic set, or a gesture the in-flight call will
                            // carry in its `settle`. Logged because the second case is the one
                            // shape of this guard the user can FEEL — the switch moves and
                            // nothing happens — and with no line here a guard stuck shut was
                            // invisible in the log by construction.
                            Logger.shared.debug("Launch-at-login: no round-trip started for \(enabled) (echo, or one already in flight)")
                            return
                        }
                        updateLoginItem(enabled)
                    }
            } caption: {
                if loginItemNeedsApproval {
                    HStack(spacing: 4) {
                        Text("Approval needed — allow SyncCloud in Login Items settings.")
                        Button("Open Login Items Settings") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                } else {
                    Text("Automatically start SyncCloud when you log in to your Mac.")
                }
            }

            SettingsSection(
                "Startup",
                caption: "Panes reopen at the folders they showed when you last quit (falling back to the root if a folder is gone). Sort changes made from the pane menus are remembered here too."
            ) {
                Toggle("Show hidden files by default", isOn: $showHiddenByDefault)
                Toggle("Reopen panes where I left off", isOn: $restoreLastFocus)
                SettingsRow("Sort panes by") {
                    Picker("Sort panes by", selection: $settings.defaultSortOption) {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection {
                Toggle("Notify when operations finish in the background", isOn: $notifyInBackground)
                    .onChange(of: notifyInBackground) { _, enabled in
                        if enabled {
                            // Capture the result: a denied request used to vanish, leaving the
                            // toggle on and the user waiting for notifications that never come.
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                                Task { @MainActor in notificationsDenied = !granted }
                            }
                        } else {
                            // The hint only matters while the feature is on.
                            notificationsDenied = false
                        }
                    }
            } caption: {
                if notifyInBackground && notificationsDenied {
                    Text("Notifications are disabled in System Settings — allow SyncCloud under Notifications to see these alerts.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Shows a system notification when a copy, sync, or verify finishes while SyncCloud isn't the active app. Requires notification permission.")
                }
            }

            SettingsSection(caption: "Shows a confirmation if you try to quit while a copy, move, or delete is still running.") {
                Toggle("Warn before quitting during file operations", isOn: $warnBeforeQuit)
            }
        }
        .task {
            readLoginItemState()
            readNotificationAuthorization()
        }
        // Approving the login item (and notification permission) happens in System Settings,
        // so these footers' hints go stale exactly while this tab is still open. Coming back
        // to the app re-activates it — re-read so the hints clear without reopening the tab.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLoginItemState()
            readNotificationAuthorization()
        }
    }

    /// Reflects the real notification authorization into the footer hint. Only `denied` shows
    /// the warning: `notDetermined` means the request prompt is still ahead, and provisional/
    /// authorized both deliver.
    private func readNotificationAuthorization() {
        guard notifyInBackground else { return }
        UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
            let denied = notificationSettings.authorizationStatus == .denied
            Task { @MainActor in notificationsDenied = denied }
        }
    }

    /// Reflects the real service state into the toggle and approval hint. A pending
    /// approval counts as "on": the item *is* registered, just not yet consented to.
    ///
    /// Dated against the echo guard: this runs on `.task` and on EVERY app re-activation, so
    /// without the epoch check a cmd-tab away and back mid-gesture published a service state
    /// that predated the user's flip, moving the toggle out from under the running round-trip.
    /// That call then settled against the "moved" toggle and drove the service back, losing a
    /// registration that had succeeded.
    private func readLoginItemState() {
        Task {
            let epoch = loginItemEcho.epoch
            let status = await Self.readStatusOffMain()
            guard loginItemEcho.mayPublishStatus(readAt: epoch, at: .now) else { return }
            applyLoginItemState(status)
        }
    }

    /// Publishes just the approval hint, leaving the toggle where the user put it. Used when a
    /// failing round-trip's status re-read is the freshest thing we know but the toggle has
    /// already moved on — `applyLoginItemState` would overwrite that move.
    private func applyApprovalHint(_ status: SMAppService.Status) {
        loginItemNeedsApproval = (status == .requiresApproval)
    }

    /// Publishes a freshly read service status to the view state. Marking the value applied in
    /// the same main-actor turn as the toggle keeps `onChange` from treating the programmatic
    /// set as a user gesture (initial read, failure revert).
    ///
    /// `adoptedStatus` rather than `markApplied`: this write TAKES the toggle, so any round-trip
    /// whose claim had already expired must stop speaking for it — see `adoptedStatus`.
    private func applyLoginItemState(_ status: SMAppService.Status) {
        launchAtLogin = (status == .enabled || status == .requiresApproval)
        loginItemNeedsApproval = (status == .requiresApproval)
        loginItemEcho.adoptedStatus(launchAtLogin)
    }

    /// Registers/unregisters the login item, reverting the toggle to the real service state on
    /// failure so the UI never claims a state the system rejected.
    private func updateLoginItem(_ enabled: Bool) {
        // Synchronously, before the `Task` is even scheduled: two `onChange` turns must not
        // both pass `shouldStartRoundTrip` and start a call apiece.
        let token = loginItemEcho.beginRoundTrip(at: .now)
        Task {
            do {
                let needsApproval = try await Self.applyLoginItemOffMain(enabled)
                // A superseded settle (nil) owns nothing, so it publishes nothing: this hint was
                // sampled off-main and lands an actor hop later, and whatever superseded the call
                // — a fresher status read, a later gesture — knows better than it does.
                guard let followUp = loginItemEcho.settle(
                    token: token, applied: enabled, toggle: launchAtLogin, succeeded: true) else { return }
                loginItemNeedsApproval = needsApproval
                if needsApproval {
                    Logger.shared.info("Login item registered; awaiting user approval in Login Items settings")
                }
                perform(followUp, status: nil)
            } catch {
                // Logged before the ownership test: the call really did fail, and that is worth
                // a line whether or not this round-trip still speaks for the toggle.
                Logger.shared.error("Failed to \(enabled ? "register" : "unregister") launch-at-login item: \(error.localizedDescription)")
                let status = await Self.readStatusOffMain()
                guard let followUp = loginItemEcho.settle(
                    token: token, applied: enabled, toggle: launchAtLogin, succeeded: false) else { return }
                perform(followUp, status: status)
            }
        }
    }

    /// Carries out what `LoginItemEchoGuard.settle` decided. `status` is the freshly re-read
    /// service status, available only on the failure path.
    private func perform(_ followUp: LoginItemFollowUp, status: SMAppService.Status?) {
        switch followUp {
        case .settled:
            break
        case .adoptServiceState:
            if let status { applyLoginItemState(status) }
        case .reapply(let value, let refreshApprovalHint):
            if refreshApprovalHint, let status { applyApprovalHint(status) }
            updateLoginItem(value)
        }
    }

    /// Reads `SMAppService.mainApp.status` detached: the getter is a synchronous XPC call
    /// that must not run on the main thread (the same hazard that defers the initial read
    /// out of view init).
    private static func readStatusOffMain() async -> SMAppService.Status {
        await Task.detached(priority: .userInitiated) {
            SMAppService.mainApp.status
        }.value
    }

    /// Runs the status check plus register/unregister round-trip detached — all three are
    /// synchronous XPC calls. Returns whether the item now awaits approval in Login Items.
    private static func applyLoginItemOffMain(_ enabled: Bool) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let status = SMAppService.mainApp.status
            if enabled {
                if status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if status == .enabled || status == .requiresApproval {
                // Unregistering a pending-approval item withdraws it from Login Items.
                try SMAppService.mainApp.unregister()
            }
            return SMAppService.mainApp.status == .requiresApproval
        }.value
    }
}

// MARK: - Appearance

/// Theme, accent hue, glass material and surface shape, all shared with MacApp through
/// UserDefaults.
///
/// Theme (light/dark), Glass effect (material) and Content surface (shape) are deliberately
/// separate controls: any combination is valid. The latter two were entangled before — "Solid"
/// appeared in the shape picker and silently overrode the material one.
///
/// Theme leads the tab because it is the broadest of the four: the others all decide how a
/// surface reads *within* an appearance, so choosing light vs dark first is what makes them
/// meaningful. Unlike the others it renders nothing here — `ContentView` pushes it to NSApp.
struct AppearanceSettingsTab: View {
    @AppStorage(LiquidGlass.appearanceModeKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    /// The resolved theme; `.system` (follow macOS) if unrecognized.
    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    @AppStorage(FontSize.defaultsKey) private var fontSizePercent: Int = FontSize.medium.percent

    /// The resolved text size. `FontSize.init(percent:)` clamps, so a value stored before the
    /// range last moved is honoured rather than discarded.
    private var fontSize: FontSize { FontSize(percent: fontSizePercent) }

    /// The resolved row spacing; `.comfortable` (the standard rows) if unrecognized.
    private var listDensity: ListDensity { ListDensity(rawValue: listDensityRaw) ?? .comfortable }

    /// The two settings as one value, for the preset row — which writes both and stores neither.
    private var sizeBinding: Binding<FontSize> {
        Binding(get: { fontSize }, set: { fontSizePercent = $0.percent })
    }

    private var densityBinding: Binding<ListDensity> {
        Binding(get: { listDensity }, set: { listDensityRaw = $0.rawValue })
    }

    private var selectedHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: selectedHueRaw) ?? .blue
    }

    private var selectedSurfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified
    }

    var body: some View {
        SettingsPage {
            SettingsSection("Theme", caption: appearanceMode.detail) {
                Picker("Theme", selection: $appearanceModeRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(selectedHue)
            }

            AccentColorSection(selectedHue: selectedHue,
                               onSelect: { selectedHueRaw = $0.rawValue })

            SettingsSection("Glass effect", caption: glassLevel.detail) {
                Picker("Glass effect", selection: $glassLevelRaw) {
                    ForEach(GlassLevel.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(selectedHue)
            }

            SettingsSection(
                "Tint",
                caption: selectedHue == .none
                    ? "Choose an accent color above to tint the panes and Differences area."
                    : "Washes the panes and Differences area with the accent color chosen above."
            ) {
                HStack(spacing: 12) {
                    // The slider's own label is hidden, not dropped: the section title above
                    // already says "Tint", and two of them would read as two controls. It stays
                    // in the accessibility tree.
                    Slider(value: $surfaceTint, in: 0.0...1.0) {
                        Text("Tint")
                    } minimumValueLabel: {
                        Text("Subtle")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    } maximumValueLabel: {
                        Text("Vivid")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .labelsHidden()
                    .accessibilityValue("\(Int(surfaceTint * 100)) percent")
                    .disabled(selectedHue == .none)
                    Text("\(Int(surfaceTint * 100))%")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }

            SettingsSection("Content surface", caption: selectedSurfaceStyle.detail) {
                Picker("Content surface", selection: $surfaceStyleRaw) {
                    ForEach(SurfaceStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(selectedHue)
            }

            // **Text size and row spacing are one section, because they are one question.**
            // They shipped as two adjacent segmented pickers with 190 characters of caption
            // between them and no hint that they were related — both answer "how much do you
            // want on screen?", and somebody who finds everything too small has to work out
            // that two separate controls are involved. The preset row is the shortcut over
            // them; the controls underneath are what keep combinations the row does not offer
            // (large text with compact rows, above all) reachable.
            SettingsSection(
                "Size & spacing",
                caption: SizePreset.caption(fontSize: fontSize, density: listDensity)
            ) {
                SizePresetRow(fontSize: sizeBinding, density: densityBinding)

                LabeledContent("Text size") {
                    HStack(spacing: 10) {
                        Text("A")
                            .scaledFont(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(fontSizePercent) },
                                set: { fontSizePercent = FontSize(percent: Int($0.rounded())).percent }
                            ),
                            in: Double(FontSize.minimumPercent)...Double(FontSize.maximumPercent),
                            step: Double(FontSize.step)
                        )
                        .labelsHidden()
                        .accessibilityValue("\(fontSize.percent) percent")
                        // **A tooltip rather than a caption line**, and the reason is measured:
                        // Appearance is the tallest tab and this section already carries two
                        // lines of prose — its own state caption and Row spacing's. A third put
                        // the tab 19pt past the opening a 1280×800 display gives it
                        // (`appearanceKeepsRoomForACopyEdit`). The claim is worth keeping
                        // somewhere, because it is the non-obvious half of the setting: 125% is
                        // 125% for a caption and 100% for a title.
                        .help(fontSize.detail)
                        Text("A")
                            .scaledFont(.system(size: 15))
                            .foregroundStyle(.secondary)
                        Text("\(fontSize.percent)%")
                            .scaledFont(.caption.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }

                // "Row spacing", not the "List density" this shipped as: density is a word from
                // the implementation, spacing is what the person is changing, and it reads as a
                // pair with "Text size" directly above. The option names and the stored key are
                // deliberately untouched — `ListDensity.defaultsKey` is still `listDensity`.
                LabeledContent("Row spacing") {
                    Picker("Row spacing", selection: $listDensityRaw) {
                        ForEach(ListDensity.allCases) { density in
                            Text(density.displayName).tag(density.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accentedSegments(selectedHue)
                    .fixedSize()
                }

                Text(listDensity.detail)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A selectable hue option for the liquid glass accent color.
/// Internal rather than file-private: `AccentColorSection` (the accent picker's own file) builds
/// the row of these, and the snapshot tests render it.
struct HueOptionView: View {
    let hue: LiquidGlassHue
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    swatch
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .strokeBorder(isSelected ? Color.primary.opacity(0.4) : .clear, lineWidth: 2)
                        )
                        .shadow(color: swatchShadowColor, radius: isSelected ? 5 : 1.5)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .scaledFont(.system(size: 13, weight: .semibold))
                            // The checkmark sits on the swatch's own fill, so it pairs with that
                            // fill's luminance — hardcoded white was ~2.1:1 on amber. "None" has no
                            // fill of its own (a neutral disc deferring to the system accent), so it
                            // tracks the appearance via `.primary` like the disc does.
                            .foregroundStyle(hue == .none ? Color.primary : .onFillLabel(hue.accentColor))
                            .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0, y: 0.5)
                    }
                }
                Text(hue.displayName)
                    .scaledFont(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    // Twelve hues share one row; the longest name ("Graphite") shrinks to stay on a
                    // single line rather than wrapping in its narrow slot.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.segment, tint: hue.accentColor, shape: .roundedRect(8)))
    }

    /// The colored disc for a hue, or a neutral slashed disc for "None".
    @ViewBuilder
    private var swatch: some View {
        if hue == .none {
            ZStack {
                Circle().fill(Color(nsColor: .controlBackgroundColor))
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: 1.5, height: 44)
                    .rotationEffect(.degrees(45))
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        } else {
            Circle().fill(hue.accentColor)
        }
    }

    private var swatchShadowColor: Color {
        hue == .none ? Color.black.opacity(0.2) : hue.accentColor.opacity(0.4)
    }
}

// MARK: - Sources

/// The sources panes can be pointed at: the cloud accounts discovered on this Mac, and the plain
/// folders the user added. Two sub-sections, because they are two different kinds of thing — one is
/// found, the other is chosen — and the controls differ accordingly: a cloud account can be
/// refreshed but never removed, a folder can be removed but never discovered.
struct ProvidersSettingsTab: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var isRefreshingProviders = false
    /// Ids of the rows the user has opened. Collapsed is the default and the point: this tab grows
    /// with every account the Mac has plus every folder added, and at four expanded rows the list
    /// already scrolls past the sheet. State, not a persisted default — which row you last opened
    /// is not a preference, and restoring it would reopen the scroll problem on the next launch.
    @State private var expandedIds: Set<String> = []

    private var cloudProviders: [CloudProvider] {
        settings.availableProviders.filter { !$0.isLocalFolder }
    }

    private var folderProviders: [CloudProvider] {
        settings.availableProviders.filter(\.isLocalFolder)
    }

    var body: some View {
        SettingsPage {
            SettingsSection(
                caption: "Cloud accounts are discovered from ~/Library/CloudStorage. Disabled sources stay configured but are hidden from the pane sidebar. At least one source must remain enabled."
            ) {
                HStack {
                    Text("Cloud providers")
                        .scaledFont(.body.weight(.medium))
                    Spacer()
                    Button(action: refreshProviders) {
                        Label(
                            isRefreshingProviders ? "Refreshing…" : "Refresh",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(isRefreshingProviders)
                    .controlSize(.small)
                }
            }

            // This tab is the one that legitimately keeps scrolling: it grows with every
            // provider the Mac has, so no sheet height can promise to hold it. Collapsed rows are
            // what keep that growth linear in sources rather than in sources × four fields.
            ForEach(cloudProviders) { provider in
                Divider()
                ProviderSettingsSection(provider: provider, isExpanded: expansionBinding(provider.id))
            }

            Divider()

            SettingsSection(
                caption: "Any folder on this Mac can be a source — Compare and Organize work the same over it. Folders you add appear in every workspace. Removing one leaves the folder itself untouched."
            ) {
                HStack {
                    Text("Local folders")
                        .scaledFont(.body.weight(.medium))
                    Spacer()
                    Button(action: addFolder) {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .controlSize(.small)
                }

                if folderProviders.isEmpty {
                    Text("No folders added.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                SettingsRow("Check folder names against") {
                    Picker("Check folder names against", selection: $settings.folderNameRule) {
                        ForEach(FolderNameRuleOption.all) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help(
                        "A folder accepts any name, so \"risky name\" has no meaning until you say where the files are headed. Organize and the pane badges check names under a folder source against this."
                    )
                }
            }

            ForEach(folderProviders) { provider in
                Divider()
                ProviderSettingsSection(provider: provider, isExpanded: expansionBinding(provider.id))
            }
        }
    }

    /// One row's open/closed state. A binding over the shared set rather than per-row `@State`, so
    /// a row that is rebuilt when discovery republishes `availableProviders` — which happens on
    /// every path edit, every rename, every Refresh — doesn't silently snap shut mid-edit.
    private func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedIds.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedIds.insert(id)
                } else {
                    expandedIds.remove(id)
                }
            }
        )
    }

    private func refreshProviders() {
        guard !isRefreshingProviders else { return }
        isRefreshingProviders = true
        Task {
            await settings.discoverProviders()
            await MainActor.run { isRefreshingProviders = false }
        }
    }

    /// Picks a folder and adds it as a source — opening the new row, so the thing that just
    /// appeared is the thing you can see. Adding a folder that is already a source opens *that*
    /// row instead of adding a second (see `SettingsManager.addFolderSource`).
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to use as a source"
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        expandedIds.insert(settings.addFolderSource(path: url.path))
    }
}

/// The rulesets a folder source's names can be checked against, in the order the picker lists them.
///
/// Only the two that HAVE rules, plus off. iCloud and Google Drive accept anything the local
/// filesystem does, so offering them would be offering two more spellings of "don't check" —
/// three ways to say one thing, two of which look like they mean something.
struct FolderNameRuleOption: Identifiable {
    static let all: [FolderNameRuleOption] = [
        .init(value: .oneDrive, label: "OneDrive (strictest)"),
        .init(value: .dropBox, label: "Dropbox"),
        .init(value: .localFolder, label: "Don't check"),
    ]

    let value: CloudProvider.ProviderType
    let label: String
    var id: String { value.rawValue }

    init(value: CloudProvider.ProviderType, label: String) {
        self.value = value
        self.label = label
    }
}

/// One source's rows: identity + enable switch, then — once opened — its root-path config.
struct ProviderSettingsSection: View {
    let provider: CloudProvider
    /// Whether the path configuration is showing. The header line is always there.
    @Binding var isExpanded: Bool
    @EnvironmentObject var settings: SettingsManager
    // The path draft is a value type rather than a bare String: Reset, focus-blur commit, and the
    // discovery refresh all move it, and getting Reset wrong left the field blank. See
    // `ProviderPathDraft`.
    @State private var pathDraft = ProviderPathDraft()
    @State private var draftName: String = ""
    // Both editable fields share one commit model: Return or focus-loss commits,
    // so each needs its own focus state to observe its own blur.
    @FocusState private var nameFieldFocused: Bool
    @FocusState private var pathFieldFocused: Bool

    /// The display name of the source that already owns a folder this row's Location edit was
    /// refused for, or nil when the last commit was accepted. Drives the line under the field —
    /// the refusal has to say *which* source holds the folder, because "that didn't work" leaves
    /// the user re-typing the same path.
    @State private var refusedDuplicateOwner: String?

    private var isEnabled: Bool {
        settings.isEnabled(provider.id)
    }

    var body: some View {
        SettingsSection {
            HStack(spacing: 12) {
                ProviderLogo(provider.imageName, size: 26)

                VStack(alignment: .leading, spacing: 2) {
                    // The name itself is the rename affordance: click to edit in place.
                    // Enter or clicking away commits; emptying it restores the default.
                    // labelsHidden keeps the grouped Form from rendering a leading
                    // "Provider name" label and right-aligning the value; the name
                    // must sit in place of the title, next to the icon.
                    TextField("Provider name", text: $draftName)
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .scaledFont(.body.weight(.medium))
                        .focused($nameFieldFocused)
                        .onSubmit { commitName() }
                        .onChange(of: nameFieldFocused) { _, focused in
                            if !focused { commitName() }
                        }
                        .help("Click to rename. Clear the name to restore the default.")
                    // What identifies this source at a glance while the row is shut. A cloud
                    // account is identified by its id (`OneDrive-Personal`) — that IS the
                    // account, and its path is a consequence of it. A folder source's id is a
                    // UUID that says nothing to anyone; the folder IS the path, so that shows.
                    Text(provider.isLocalFolder ? provider.path : provider.id)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(provider.isLocalFolder ? provider.path : provider.id)
                }

                Spacer()

                // SettingsManager owns validity (re-checked on discovery/refresh and
                // path edits), so re-renders here never stat the disk.
                StatusBadge(isValid: settings.isPathValid(for: provider.id))

                Toggle("", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(isEnabled && !settings.canDisable(provider.id))
                    .help(
                        isEnabled && !settings.canDisable(provider.id)
                            ? "At least one source must remain enabled."
                            : "Show \(provider.displayName) in the pane sidebar."
                    )

                disclosureButton
            }
            .padding(.vertical, 2)
            .onAppear {
                pathDraft.adopt(provider.path)
                draftName = provider.displayName
                // A refusal is about one edit, not about the row. Re-mounting starts clean.
                refusedDuplicateOwner = nil
            }
            .onChange(of: provider.path) { _, updated in
                pathDraft.adoptExternalChange(to: updated, isEditing: pathFieldFocused)
            }
            .onChange(of: provider.displayName) { _, updated in
                if !nameFieldFocused && draftName != updated {
                    draftName = updated
                }
            }

            if isExpanded {
                // The path gets its own full-width line rather than sharing one with its label.
                // Beside the label it had ~300pt, and every provider under
                // ~/Library/CloudStorage runs past that — the paths were clipped at the pane edge
                // with no ellipsis, so the tail that distinguishes them
                // (…/OneDrive-Personal/Documents from …/Desktop) was the part you couldn't see.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location")
                    // Mirrors the name field above: Enter or clicking away commits.
                    // No Save button — focus-loss covers the same ground, so the two
                    // fields commit through one identical set of triggers.
                    TextField("Synchronized path", text: $pathDraft.value)
                        .textFieldStyle(.plain)
                        .scaledFont(.system(.callout, design: .monospaced))
                        .labelsHidden()
                        .focused($pathFieldFocused)
                        .onSubmit { commitPath() }
                        .onChange(of: pathFieldFocused) { _, focused in
                            if !focused { commitPath() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // A TextField scrolls rather than ellipsizing, so a path longer than even the
                        // full width still hides its tail. The tooltip is the backstop — the same
                        // answer the ignored-items list already uses for long root-relative paths.
                        .help(pathDraft.value)

                    // Only ever set for a folder source, and cleared by the next accepted commit.
                    if let owner = refusedDuplicateOwner {
                        Text("That folder is already \(owner). One folder gets one source.")
                            .scaledFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(
                                "Location not changed. That folder is already \(owner).")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!isEnabled)

                HStack(spacing: 8) {
                    Button("Browse…") { selectDirectory() }
                    // A folder source has no discovered default to reset TO — the user chose
                    // the path, and that choice is the whole record. Remove takes its place: the
                    // one thing a folder source can do that a cloud account cannot.
                    if provider.isLocalFolder {
                        Button("Remove", role: .destructive) { settings.removeFolderSource(id: provider.id) }
                    } else {
                        Button("Reset") { resetToDefault() }
                    }
                    Button("Show in Finder") { openInFinder() }
                    Spacer()
                }
                .controlSize(.small)
                // Remove stays live on a disabled source: a folder switched off is exactly the
                // one you are most likely to be removing, and leaving the only way to get rid of
                // it behind a toggle you have to switch back on first is a trap.
                .disabled(!isEnabled && !provider.isLocalFolder)
            }
        }
    }

    /// Opens and shuts the row. Down-chevron to open, up-chevron to shut — the arrow points at
    /// where the content will be, not at where it is.
    private var disclosureButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                // A bare chevron is a ~7pt target. The frame is the hit area, not the drawing.
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chromeHover()
        .help(isExpanded ? "Hide \(provider.displayName)'s location" : "Show \(provider.displayName)'s location")
        .accessibilityLabel(isExpanded ? "Collapse \(provider.displayName)" : "Expand \(provider.displayName)")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.isEnabled(provider.id) },
            set: { settings.setEnabled($0, for: provider.id) }
        )
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select root directory for \(provider.displayName)"

        if panel.runModal() == .OK {
            if let url = panel.url {
                pathDraft.value = url.path
                commitPath()
            }
        }
    }

    private func resetToDefault() {
        settings.resetPath(for: provider.id)
        // Repopulate rather than blank. Rediscovery is async, so `provider.path` is still the old
        // effective value here: with no override that value already IS the default and no
        // `onChange(of: provider.path)` is coming to fill the field in, and with an override it is
        // corrected by that onChange as soon as discovery lands — including while this field still
        // holds focus, which clicking this button does not take away. The draft remembers the reset
        // so that correction is adopted instead of being declined as mid-edit; without that, the
        // blur after Reset commits the stale override straight back. See `ProviderPathDraft.reset`.
        pathDraft.reset(toEffective: provider.path)
    }

    private func openInFinder() {
        let url = URL(fileURLWithPath: (provider.path as NSString).expandingTildeInPath)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // Both fields commit on Return AND on focus-loss (one shared model), so a blur that
    // lands on an unchanged value must be a harmless no-op — hence both guard on
    // ProviderFieldEdit.shouldCommit before writing.
    private func commitPath() {
        let normalized = ProviderFieldEdit.normalized(pathDraft.value)
        pathDraft.value = normalized
        guard ProviderFieldEdit.shouldCommit(draft: normalized, committed: provider.path) else { return }
        switch settings.setPath(normalized, for: provider.id) {
        case .changed, .unchanged:
            refusedDuplicateOwner = nil
        case .refusedDuplicate(let existingId):
            // Put the field back to what the source actually points at. Nothing was written, so no
            // `onChange(of: provider.path)` is coming to do it — and leaving the refused text in
            // place would show a Location this source does not have.
            refusedDuplicateOwner = settings.availableProviders
                .first { $0.id == existingId }
                .map { "\($0.displayName)'s folder" } ?? "another source's folder"
            pathDraft.adopt(provider.path)
        }
    }

    private func commitName() {
        let normalized = ProviderFieldEdit.normalized(draftName)
        guard ProviderFieldEdit.shouldCommit(draft: normalized, committed: provider.displayName) else {
            draftName = normalized
            return
        }
        // Empty clears the override; the default name flows back through discovery
        // and the onChange(of: provider.displayName) refreshes the field.
        settings.setCustomName(normalized, for: provider.id)
        draftName = normalized.isEmpty ? provider.displayName : normalized
    }
}

/// Normalization applied to the provider text fields (path and name) before committing.
/// Pure and internal so tests can pin the trimming without instantiating the view.
enum ProviderFieldEdit {
    /// Pasted values often arrive with a trailing space or newline (terminal copies, drag-outs).
    /// A path stored verbatim with trailing whitespace fails validation and scans empty with no
    /// visual hint — the badge just goes red — so both fields trim whitespace and newlines alike.
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a commit should actually write. Both fields now commit on Return *and* on
    /// focus-loss (one shared model), so an unchanged blur must be a no-op: committing is
    /// gated on the normalized draft differing from the currently stored value.
    static func shouldCommit(draft: String, committed: String) -> Bool {
        normalized(draft) != committed
    }
}

/// The Location field's draft text, modeled as a value so its lifecycle — adopting an external
/// discovery change, and repopulating after "Reset" — is decided in one testable place instead of
/// inline in three SwiftUI closures.
///
/// It exists because "Reset" got that lifecycle wrong in a way no view-level reasoning caught. It
/// used to blank the draft and lean on `onChange(of: provider.path)` to refill it. That refresh
/// only fires when the published path actually CHANGES — and resetting a provider that has NO
/// override removes a defaults key that was never there, so nothing changed, nothing refreshed,
/// and the Location field simply sat empty. A later focus-blur then committed that empty string,
/// which `SettingsManager.setPath` records as "User cleared custom path mapping" for a provider
/// that never had one: a misleading log line and a pointless rediscovery pass.
struct ProviderPathDraft: Equatable {
    /// The text currently in the field. A plain `var` because the `TextField` binds straight to it.
    var value: String = ""

    /// What "Reset" put in the field, held until the rediscovery it kicked off lands — or `nil`
    /// when no reset is outstanding. Stored as the TEXT rather than a bool so it self-clears: the
    /// `TextField` binds straight to `value`, so typing is invisible to this type, and the only
    /// way to tell "still showing what Reset left" from "the user has since typed over it" is to
    /// compare. See `reset(toEffective:)` for why the distinction decides who wins.
    private var textAwaitingReset: String?

    /// The row appeared: start on the provider's effective (default or overridden) path.
    mutating func adopt(_ path: String) {
        value = path
        textAwaitingReset = nil
    }

    /// An external change to the published path landed (a discovery/refresh pass). Adopt it only
    /// when the user isn't actively editing this field — otherwise a concurrent
    /// `discoverProviders()` would silently discard their uncommitted draft.
    ///
    /// The one exception is the rediscovery the user's own "Reset" started. That refresh is not a
    /// background pass racing their typing, it is the ANSWER to the button they just pressed —
    /// and clicking a macOS button does not blur the text field, so it arrives with
    /// `isEditing: true` and the ordinary guard would decline it. Declining it is what re-committed
    /// the cleared override on the next blur (see `reset(toEffective:)`). The exception is narrow:
    /// it applies only while the field still shows exactly what Reset left there, so a user who
    /// started typing a replacement path keeps their draft, as always.
    mutating func adoptExternalChange(to updated: String, isEditing: Bool) {
        let isResetLanding = textAwaitingReset == value
        guard !isEditing || isResetLanding else { return }
        textAwaitingReset = nil
        guard value != updated else { return }
        value = updated
    }

    /// "Reset" was pressed. Echo the provider's effective path rather than blanking the field:
    /// with no override in play that value already IS the default and no refresh is coming, and
    /// with one in play it is replaced by `adoptExternalChange` the moment the async rediscovery
    /// lands. Either way the field never shows an empty path the user didn't type.
    ///
    /// Remembering that echoed text is what makes Reset actually stick when an override WAS in
    /// play. `SettingsManager.resetPath` rediscovers asynchronously, so the effective path echoed
    /// here is still the old override; if the correction that follows is declined for being
    /// mid-edit, the field keeps showing the override and the blur commits it straight back —
    /// `shouldCommit(draft: oldOverride, committed: default)` is true, so `setPath` restores the
    /// very override the user just cleared. (The pre-refactor code escaped that only because its
    /// draft was `""`, i.e. by way of the blank-field bug this type exists to fix.)
    mutating func reset(toEffective path: String) {
        value = path
        textAwaitingReset = path
    }
}

/// One row of a fixed-choice settings picker: the value it stores and the label it shows.
struct SettingsPickerOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }
}

/// Row lists for the numeric Settings pickers, and the rule that keeps them honest when the
/// persisted value isn't one of the offered rows.
///
/// A `Picker` whose selection matches none of its `.tag` values renders with NOTHING selected while
/// that value stays fully in effect behind it: the scan really is using a 3-second tolerance, the
/// picker just refuses to say so. Worse, the control is then one click from destroying it — the
/// user's first interaction with a blank-looking picker replaces a setting they never knowingly
/// chose. Off-list values are not hypothetical: an older build's option set, a `defaults write`, or
/// a hand-edited plist all produce them.
///
/// The answer is to SHOW the stored value, not to coerce it. Snapping to the nearest offered option
/// is the same destruction one click earlier, just silent. The adjacent Cloud-model picker can map
/// a superseded model id onto its family's current one because that equivalence genuinely exists;
/// no such equivalence exists between two numbers, so these pickers take the other honest route —
/// one extra row carrying the stored value, labeled by the same formatter as its neighbours and
/// sorted into place so the list still reads as a scale.
///
/// Labels are *derived* from those formatters rather than spelled per row, for the same reason
/// `CloudFilingProtocol.selectableModelOptions` is one list and not two: the extra row and the
/// fixed rows cannot then drift into two different vocabularies for the same quantity.
enum SettingsPickerOptions {

    // MARK: - The widening rule

    /// `options`, plus one extra row carrying `stored` when no option already holds that value.
    /// The extra row is inserted in value order so the list still reads as an ascending scale.
    static func including<Value: Hashable & Comparable>(
        stored: Value,
        in options: [SettingsPickerOption<Value>],
        label: (Value) -> String
    ) -> [SettingsPickerOption<Value>] {
        guard !options.contains(where: { $0.value == stored }) else { return options }
        let extra = SettingsPickerOption(value: stored, label: label(stored))
        guard let insertion = options.firstIndex(where: { $0.value > stored }) else {
            return options + [extra]
        }
        var widened = options
        widened.insert(extra, at: insertion)
        return widened
    }

    // MARK: - Labels

    /// A number without a pointless ".0" tail. Guarded on finiteness and Int range because the
    /// value can arrive from `defaults write`, which will happily store 1e300 or a NaN.
    static func trimmed(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        guard value == value.rounded(), abs(value) < 1e15 else { return "\(value)" }
        return String(Int(value))
    }

    static func dateToleranceLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "Exact match" }
        if seconds < 60 { return seconds == 1 ? "1 second" : "\(trimmed(seconds)) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(trimmed(minutes)) minutes"
    }

    static func fileSizeLabel(_ bytes: Int) -> String {
        guard bytes > 0 else { return "No minimum" }
        if bytes >= 1_048_576 { return "\(trimmed(Double(bytes) / 1_048_576)) MB" }
        if bytes >= 1024 { return "\(trimmed(Double(bytes) / 1024)) KB" }
        return bytes == 1 ? "1 byte" : "\(bytes) bytes"
    }

    /// Rounded to two decimal places before trimming: 0.6 is not exactly representable, so a bare
    /// `fraction * 100` renders as "60.00000000000001%".
    static func percentLabel(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "\(fraction)" }
        return "\(trimmed(((fraction * 100) * 100).rounded() / 100))%"
    }

    static func budgetLabel(_ usd: Double) -> String {
        usd > 0 ? "$\(trimmed(usd))" : "Off (no limit)"
    }

    // MARK: - The five numeric pickers

    static func dateTolerance(including stored: Double) -> [SettingsPickerOption<Double>] {
        including(stored: stored, in: rows([0, 1, 2, 5, 60], dateToleranceLabel), label: dateToleranceLabel)
    }

    static func minFileSize(including stored: Int) -> [SettingsPickerOption<Int>] {
        including(stored: stored, in: rows([0, 4096, 102_400, 1_048_576], fileSizeLabel), label: fileSizeLabel)
    }

    static func overlapThreshold(including stored: Double) -> [SettingsPickerOption<Double>] {
        including(stored: stored, in: rows([0.5, 0.6, 0.7, 0.8, 0.9], percentLabel), label: percentLabel)
    }

    static func monthlyBudget(including stored: Double) -> [SettingsPickerOption<Double>] {
        including(stored: stored, in: rows([0, 1, 5, 10, 25, 50], budgetLabel), label: budgetLabel)
    }

    static func totalBudget(including stored: Double) -> [SettingsPickerOption<Double>] {
        including(stored: stored, in: rows([0, 5, 10, 25, 50, 100], budgetLabel), label: budgetLabel)
    }

    private static func rows<Value: Hashable>(
        _ values: [Value], _ label: (Value) -> String
    ) -> [SettingsPickerOption<Value>] {
        values.map { SettingsPickerOption(value: $0, label: label($0)) }
    }
}

// MARK: - Sync

/// Behavior of difference scanning and comparison: date tolerance, checksum verification,
/// the delete confirmation, and the two ignore mechanisms (remembered items and name patterns).
struct SyncSettingsTab: View {
    @EnvironmentObject var settings: SettingsManager
    let syncManager: FileSyncManager?
    @AppStorage(GeneralSettings.confirmBeforeDeleteKey) private var confirmBeforeDelete: Bool = true
    @AppStorage(GeneralSettings.confirmBeforeTransferKey) private var confirmBeforeTransfer: Bool = true
    @State private var patternDraft = ""

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Conflicts",
                caption: "Applies to copies, moves, and syncs. Keep both renames the incoming file; Replace moves the existing file to the Trash first. Folder conflicts always ask."
            ) {
                SettingsRow("When a file already exists") {
                    Picker("When a file already exists", selection: $settings.conflictPolicy) {
                        ForEach(ConflictPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection(
                "Comparison",
                caption: "Cloud providers round file dates on upload; a small tolerance hides those false differences. Verification checksums same-size pairs that only differ by date and hides identical ones — thorough, but slower on large folders."
            ) {
                // Rows come from `SettingsPickerOptions`, which widens the list with the stored
                // value when it isn't one of them — a tolerance left by an older build or a
                // `defaults write` shows itself rather than leaving the picker blank while
                // silently governing every scan. Same treatment as the four other numeric
                // pickers; see that type for why showing beats coercing.
                SettingsRow("Treat dates as equal within") {
                    Picker("Treat dates as equal within", selection: $settings.dateToleranceSeconds) {
                        ForEach(SettingsPickerOptions.dateTolerance(including: settings.dateToleranceSeconds)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle(isOn: $settings.autoVerifySameSizeDuringScan) {
                    Text("Verify same-size files during scans")
                }
                Toggle(isOn: $settings.ignoreGoogleDriveNewerDateOnly) {
                    Text("Ignore \"newer on Google Drive\" when same size")
                }
            }

            SettingsSection(
                "Confirmations",
                caption: "Copies and moves first show what will be transferred and where; turning this off starts them immediately, including moves, with no confirmation. Deleted items go to the Trash either way and can be restored with Undo."
            ) {
                Toggle("Confirm before copying or moving", isOn: $confirmBeforeTransfer)
                Toggle("Confirm before deleting", isOn: $confirmBeforeDelete)
            }

            SettingsSection(
                "Ignored items",
                caption: "Items you ignore from the Differences list are kept here per provider pair. Remove one to see its differences again."
            ) {
                Toggle(isOn: $settings.rememberIgnoredItems) {
                    Text("Remember ignored items across rescans")
                }
                if let syncManager, let store = syncManager.ignoredItemsStore {
                    IgnoredItemsList(
                        store: store,
                        onRemove: { syncManager.unignoreRootRelative($0) },
                        onClear: { syncManager.clearAllIgnoredItems() }
                    )
                }
            }

            SettingsSection(
                "Ignored name patterns",
                caption: "Hides any item whose name matches a pattern, at any depth, in every comparison. * matches any run of characters and ? matches one."
            ) {
                ForEach(settings.ignorePatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern)
                            .scaledFont(.system(.callout, design: .monospaced))
                        Spacer()
                        Button {
                            settings.removeIgnorePattern(pattern)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .hoverInk()
                        }
                        .buttonStyle(.hoverAffordance(.inline))
                        .help("Remove this pattern")
                    }
                }
                HStack(spacing: 8) {
                    TextField("*.tmp, .DS_Store, node_modules", text: $patternDraft)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(.system(.callout, design: .monospaced))
                        .onSubmit(addPattern)
                    Button("Add", action: addPattern)
                        .disabled(IgnoreRules.normalized(patternDraft) == nil)
                }
            }
        }
    }

    private func addPattern() {
        if settings.addIgnorePattern(patternDraft) {
            patternDraft = ""
        }
    }
}

/// The remembered-ignores rows inside the Sync tab: a monospaced root-relative path per
/// entry with a remove button, plus Clear All. Split out so it can observe the store
/// directly — un-ignoring from here must repaint the list immediately.
private struct IgnoredItemsList: View {
    @ObservedObject var store: IgnoredItemsStore
    let onRemove: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        if store.rootRelativePaths.isEmpty {
            Text("Nothing ignored right now. Right-click a difference and choose Ignore to hide it.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.sortedPaths, id: \.self) { path in
                HStack {
                    Text(path)
                        .scaledFont(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    Spacer()
                    Button {
                        onRemove(path)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .hoverInk()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Stop ignoring this item")
                }
            }
            HStack {
                Spacer()
                Button("Clear All", role: .destructive, action: onClear)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Duplicates

/// How a duplicate scan decides what counts as a match. Three preferences and nothing else —
/// thin, and honestly so: this is the first place anyone hunting for the overlap threshold looks.
///
/// Split out of the old Tidy tab along with `FilingSettingsTab`. Tidy was one tab holding the
/// preferences of two workspaces that stopped sharing a home when the workspace bar went flat,
/// under a word the rest of the product had already retired. (That era's five segments —
/// Compare · Organize · Duplicates · Automations · Storage — have since folded to
/// Browse · Compare · Organize · Storage, with Duplicates and Automations as rail items inside
/// Organize.) The rule the split follows is *settings go where the work is*, not one tab per
/// workspace — Storage and Compare get no tab because they have no preferences to put in one.
struct DuplicatesSettingsTab: View {
    // The DEFAULTS KEYS keep their legacy `tidy` prefixes ("tidyMinFileSize" and friends, owned
    // by `DuplicateFinderOptions.DefaultsKey`): they are a persistence format and did not move
    // when the Tidy workspace was retired. The local names use the current vocabulary instead —
    // anyone chasing a stored value should follow the `DefaultsKey` constant, not the property.
    @AppStorage(DuplicateFinderOptions.DefaultsKey.minFileSize) private var duplicateMinFileSize: Int = 4096
    @AppStorage(DuplicateFinderOptions.DefaultsKey.overlapThreshold) private var duplicateOverlapThreshold: Double = 0.7
    @AppStorage(DuplicateFinderOptions.DefaultsKey.detectVersions) private var duplicateDetectVersions: Bool = true
    @AppStorage(DuplicateFinderOptions.DefaultsKey.detectSameText) private var duplicateDetectSameText: Bool = true

    var body: some View {
        SettingsPage {
            // Titleless, keeping the caption: the rail row above already says "Duplicates", and a
            // lone section header repeating it would read as a subdivision of a tab that has none
            // — the same redundancy that keeps Organize's first section header descriptive
            // ("Inbox and rules") rather than a repeat of its rail row. The caption carried the
            // actual explanation and is unchanged.
            SettingsSection(
                caption: "How Find Duplicates groups results. Identical detection is always checksum-verified; the overlap threshold decides when same-named folders read as overlapping vs unrelated. Reading PDFs finds a further kind — the same document downloaded twice, which providers re-stamp so its bytes differ — and is the one setting here that costs time rather than shaping results: it extracts text (never OCR, and a scan with no text layer is simply skipped), so the first pass over a large tree takes a few extra minutes and later scans reuse what it read. Changes apply on the next scan."
            ) {
                // Both row lists come from `SettingsPickerOptions` so a stored value outside the
                // offered set still displays (and survives) instead of rendering as no selection.
                SettingsRow("Ignore files smaller than") {
                    Picker("Ignore files smaller than", selection: $duplicateMinFileSize) {
                        ForEach(SettingsPickerOptions.minFileSize(including: duplicateMinFileSize)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow("Folders overlap at") {
                    Picker("Folders overlap at", selection: $duplicateOverlapThreshold) {
                        ForEach(SettingsPickerOptions.overlapThreshold(including: duplicateOverlapThreshold)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Detect versions (Report, Report (1), Report-final)", isOn: $duplicateDetectVersions)
                Toggle("Read PDFs to find copies a byte hash misses", isOn: $duplicateDetectSameText)
            }
        }
    }
}

// MARK: - Organize

/// The Organize *job*: where it goes looking for loose files, and the names it has been told to
/// stop offering to rename.
///
/// This tab used to be five subjects — the AI engine, the Claude key and model, the money that
/// path costs, the kept-name inventory, and the household roster — under one rail row, and the
/// tell was its caption: a single paragraph of nine sentences, because one caption had to explain
/// all five. The engine and its cost are now `IntelligenceSettingsTab`, the roster is
/// `PeopleSettingsTab`, and what is left here is the pair of settings that describe the job
/// rather than the machinery: which folder to scan, and what not to touch.
///
/// The old header comment defended cloud spend living here — "the caps exist because Organize can
/// call Claude, so they are *Organize's* money". That was true while the key was Organize's too.
/// Once the key has a tab, the money follows the key: they are one question ("what does the cloud
/// path cost me?") and splitting them would be the third place to look for one workflow the old
/// comment was rightly worried about.
struct FilingSettingsTab: View {
    /// Only the kept-names list needs it, and only to reach `keptNamesStore`. Optional for the
    /// same reason every other tab's is: tests and previews build the tab without an engine.
    let syncManager: FileSyncManager?
    @AppStorage(GeneralSettings.filingInboxRelativePathKey) private var filingInbox: String = "TODO"

    var body: some View {
        SettingsPage {
            // "Inbox and rules", not "Filing" and not "Organize": "filing" left the product's
            // vocabulary with the workspace rename (search keeps it as an alias keyword, the way
            // "tidy" is kept), and "Organize" would repeat the rail row above — the redundancy
            // that keeps Duplicates' lone section titleless. This header names what the group
            // holds: the loose-files inbox and the pointer to Organize ▸ Rules.
            SettingsSection("Inbox and rules", content: {
                SettingsRow("Loose-files inbox") {
                    // **The placeholder is "None", not "TODO", and that is the fix to a real
                    // complaint.** It used to show the key's default, so a field the user had
                    // deliberately emptied rendered identically to one they had never touched —
                    // greyed-out "TODO" either way — and there was no way to tell whether the
                    // setting was off. Naming the empty state is what gives the row an "off"
                    // position at all; the help text below says what that position does.
                    TextField("None", text: $filingInbox)
                        .frame(maxWidth: 180)
                        .multilineTextAlignment(.trailing)
                }
                .help("The folder (relative to the provider root) where loose files pile up — e.g. “TODO”. Organize offers it on its overview as a one-click way to narrow to that folder. It does not open there on its own; leave this blank and the offer disappears.")
                SettingsRow("Remembered rules") {
                    Text("Now live in Organize ▸ Rules")
                        .foregroundStyle(.secondary)
                }
                .help("A rule you teach by correcting a suggestion is saved — review, edit, or delete it under Rules in the Organize workspace.")
            }, caption: {
                // Names the two tabs this one hands off to. A settings tab that has had three of
                // its five sections moved out owes the reader that much: without it, "where did
                // the API key go?" has no answer on the page it used to be answered on.
                Text("Organize suggests where loose files belong, starting from the inbox folder above. What it suggests, and what the cloud pass costs, now live under **Intelligence**; the household it files for lives under **People**. Corrections you ask it to remember are saved as rules, listed under Rules in the Organize workspace.")
            })

            SettingsSection(
                "Kept names",
                caption: "Names you kept with “Always Allow This Name” after SyncCloud flagged them as ones a cloud provider may mishandle — a trailing space, a forbidden character, and so on. A kept name draws no badge anywhere it is listed, and Organize never offers to rename it. Kept names are matched exactly, so the decision covers every file with that name and follows it when it moves. Remove one to have it reported again; the files themselves are never touched either way."
            ) {
                if let store = syncManager?.keptNamesStore {
                    KeptNamesList(store: store)
                } else {
                    // No engine attached (tests, previews). The list would say the same thing an
                    // empty store does, so say it rather than leaving the caption over a void.
                    //
                    // **This branch is not the tab.** It is one fixed line; the branch above is an
                    // unbounded row-per-name list, which is why this tab is in
                    // `SettingsTab.exemptFromFitGuard` rather than in the layout suite's
                    // `mustFitTabs`. A layout test that builds the tab with `syncManager: nil`
                    // measures this line and learns nothing about what a user with kept names sees
                    // — which is exactly what the fit guard did until 2026-08-13.
                    KeptNamesList.nothingKeptNote
                }
            }
        }
    }
}

// MARK: - Intelligence

/// The suggestion engine and what it costs: the free on-device pass, the opt-in Claude pass with
/// its key and model, the spend those calls run up, and the cache that stops them being repeated.
///
/// Called "Intelligence" rather than "Claude" because the free on-device pass is half of it and a
/// vendor name would sit over a section that isn't theirs; rather than "AI & Cloud" because a
/// second "Cloud" in a rail that already has cloud *providers* under Sources answers the wrong
/// question first. `SettingsSearchIndex` is what carries "API key" and "Anthropic" here, and the
/// entries below are indexed against this tab precisely so the rail's word doesn't have to be the
/// only way in.
///
/// The four sections are one escalation, top to bottom: what runs for free, what runs for money,
/// what that money has come to, and what stops it being spent twice.
struct IntelligenceSettingsTab: View {
    /// Reaches `filingVerdictCache*` for the saved-suggestion count. Optional for the same reason
    /// every other tab's is: tests and previews build the tab without an engine.
    let syncManager: FileSyncManager?
    @AppStorage(FileSyncManager.usesAIDefaultsKey) private var filingUseAI: Bool = true
    @AppStorage(FileSyncManager.readContentsDefaultsKey) private var filingReadContents: Bool = true
    @AppStorage(FileSyncManager.usesCloudDefaultsKey) private var filingUseCloud: Bool = false
    // Default from the protocol, not a repeated literal: the classifier and the spend preflight both
    // fall back to `CloudFilingProtocol.defaultModel`, and a copy here would silently disagree with
    // them the next time the default model moves.
    @AppStorage(FileSyncManager.cloudModelDefaultsKey) private var filingCloudModel: String = CloudFilingProtocol.defaultModel
    @AppStorage(FileSyncManager.reuseVerdictsDefaultsKey) private var filingReuseVerdicts: Bool = true
    @AppStorage(FileSyncManager.monthlyBudgetCapKey) private var monthlyBudgetUSD: Double = 0
    @AppStorage(FileSyncManager.totalBudgetCapKey) private var totalBudgetUSD: Double = FileSyncManager.defaultTotalBudgetCapUSD

    /// How many saved suggestions there are. Read on appear and after a clear rather than computed
    /// in `body`: answering it touches the cache file, and `body` runs far more often than the
    /// number changes.
    @State private var savedSuggestionCount = 0

    // Cloud spend, refreshed on appear and when the history sheet closes.
    @State private var spendTotals = FilingSpendTotals()
    @State private var spendLast: FilingSpendEntry?
    @State private var showSpendHistory = false

    /// Whether the KEY AND MODEL rows can be operated. The cloud path rides on top of on-device
    /// AI, so turning either flag off takes them with it.
    ///
    /// Static and parameterised so the rule can be tested: the view itself reads `@AppStorage`,
    /// and the disabled-ness of a SwiftUI control is not observable from a unit test.
    static func cloudControlsEnabled(useAI: Bool, useCloud: Bool) -> Bool { useAI && useCloud }

    /// Whether the cloud TOGGLE itself can be operated — gated on on-device AI **and nothing
    /// else**.
    ///
    /// Deliberately not `cloudControlsEnabled`, and the distinction is not cosmetic. Putting one
    /// `.disabled(!cloudControlsEnabled)` over the whole section — which is how this was first
    /// written — disabled the toggle along with the rows it gates, and since `filingUseCloud`
    /// defaults to false the switch that turns cloud refining on could never be turned on. The
    /// entire paid path was unreachable, and every test stayed green: 215 of them, because a
    /// SwiftUI control's disabled state is invisible to all of them. It took rendering the tab to
    /// a PNG and looking at it.
    ///
    /// The general rule, which is worth more than this instance: **a control that turns something
    /// on must never be gated on that thing being on.**
    static func cloudToggleEnabled(useAI: Bool) -> Bool { useAI }

    var body: some View {
        SettingsPage {
            SettingsSection(
                "On-device",
                caption: "Free, private, and always the first pass: the on-device model (Apple Intelligence, macOS 26) runs at no cost, and where it isn’t available Organize falls back to matching on names and metadata. Reading contents gives it more to go on for files whose name says nothing. Changes apply on the next scan."
            ) {
                Toggle("Suggest folders with on-device AI (Apple Intelligence)", isOn: $filingUseAI)
                Toggle("Read file contents on-device for better signals", isOn: $filingReadContents)
            }

            SettingsSection(
                "Claude (cloud)",
                caption: "Refining is the opt-in second pass — once a scan has results, a Refine button re-asks Claude about them, billed to your API key. It is the only thing here that spends money, it never runs on its own, and you see a cost estimate before each one. To keep cost low it sends your folder names plus file names — and a short text excerpt only for files whose name says nothing — for up to 150 files per pass. Pick Haiku for the cheapest runs (roughly a penny a pass). The key is stored in the macOS Keychain."
            ) {
                Toggle("Use Claude (cloud) to refine suggestions", isOn: $filingUseCloud)
                    .disabled(!Self.cloudToggleEnabled(useAI: filingUseAI))
                    .help("Lets Organize’s Refine button send to Claude — with the key below; without one it offers to bring you back here instead. Scans stay free and on-device either way; refining is the only thing that reaches Claude, and only when you click it.")
                // Shown ALWAYS, disabled rather than absent when the toggles are off. It used to
                // be gated on `filingUseCloud && filingUseAI`, which meant "is a key stored?" —
                // the one question this row exists to answer — became unanswerable the moment
                // either toggle went off, and answering it required turning cloud filing back on.
                // A disabled row still says whether a key is there.
                // Grouped so ONE `.disabled` covers the key and the model without also covering
                // the toggle above them. The modifier used to sit on the whole `SettingsSection`,
                // which swept the toggle in and made cloud refining impossible to switch on at
                // all — see `cloudToggleEnabled`.
                Group {
                    CloudKeyRow()
                    // Read through `currentModel(for:)` so a value stored before a model refresh
                    // (e.g. "claude-opus-4-8") still lights up its family's row instead of leaving
                    // the picker blank — the scan resolves it the same way.
                    // "Cloud model" matches this row's entry in the search index above; the index
                    // documents that its titles mirror the on-screen labels, and "Model" alone did
                    // not. Rows come from `selectableModelOptions` rather than being spelled here,
                    // so ids and labels cannot drift out of step across a model refresh.
                    SettingsRow("Cloud model") {
                        Picker("Cloud model", selection: Binding(
                            get: { CloudFilingProtocol.currentModel(for: filingCloudModel) },
                            set: { filingCloudModel = $0 })) {
                            ForEach(CloudFilingProtocol.selectableModelOptions, id: \.id) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .help("Saved suggestions are per model — switching means the next Refine asks, and pays for, every file again.")
                }
                // One modifier over both rows rather than one each: they are the same control
                // surface (the key you use and the model you spend it on), and they enable
                // together — but only these two.
                .disabled(!Self.cloudControlsEnabled(useAI: filingUseAI, useCloud: filingUseCloud))
            }

            SettingsSection(
                "Cost and limits",
                caption: "Before each Refine you’ll see a cost estimate to confirm. Two caps pause cloud classification when a refine would push you past them: a monthly cap (Off by default) and a total lifetime cap (defaults to $5 as a safety backstop). Either one being reached leaves the free on-device suggestions in place until you raise or turn it off. Costs are estimated from list prices for the cloud suggestions only (the Anthropic Console is authoritative); scanning is free."
            ) {
                // What has been spent, above the caps that bound it: the numbers are what make
                // the caps mean anything, and reading "Total spent $0.42" first is what tells you
                // whether the $5 backstop below is close. As a readout strip rather than four
                // more label/value rows — these report, they don't set.
                FilingSpendReadout(totals: spendTotals, last: spendLast)
                // A cap is the one setting where a blank picker is actively dangerous: the stored
                // value keeps pausing (or not pausing) cloud scans regardless of what the control
                // shows, so an unrecognized cap has to be visible. Rows via `SettingsPickerOptions`.
                SettingsRow("Monthly budget cap") {
                    Picker("Monthly budget cap", selection: $monthlyBudgetUSD) {
                        ForEach(SettingsPickerOptions.monthlyBudget(including: monthlyBudgetUSD)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow("Total budget cap") {
                    Picker("Total budget cap", selection: $totalBudgetUSD) {
                        ForEach(SettingsPickerOptions.totalBudget(including: totalBudgetUSD)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Button("View history…") { showSpendHistory = true }
                        .disabled(spendTotals.scans == 0)
                    Button("Clear", role: .destructive) { FilingSpendStore.clear(); refreshSpend() }
                        .disabled(spendTotals.scans == 0)
                }
                .controlSize(.small)
            }

            SettingsSection(
                "Saved suggestions",
                caption: "A file that hasn’t been edited, renamed, or moved gets the same suggestion it got last time, so scanning — or refining — the same folder again doesn’t ask the model, or pay Claude, a second time. Clearing forgets every saved suggestion: the next scan asks the on-device model about each file again, and the next Refine asks — and pays — Claude again."
            ) {
                Toggle("Reuse suggestions for files that haven’t changed", isOn: $filingReuseVerdicts)
                    .disabled(!filingUseAI)
                SettingsRow("Saved suggestions") {
                    HStack(spacing: 8) {
                        Text(savedSuggestionCount == 1 ? "1 file" : "\(savedSuggestionCount) files")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("Clear") {
                            syncManager?.clearFilingVerdictCache()
                            // The non-awaiting read: `clearFilingVerdictCache` has just written the
                            // memo, so this cannot be the first load and cannot decode anything.
                            savedSuggestionCount = syncManager?.filingVerdictCacheCountNow ?? 0
                        }
                        .disabled(savedSuggestionCount == 0)
                    }
                }
            }
        }
        .onAppear(perform: refreshSpend)
        // The store's change signal — the Organize lens's history sheet (main window) can Clear
        // History while this tab is open in the Settings window, and a scan can record spend
        // mid-view. Mirrors LensWorkspaceView's observer; `receive(on:)` because `record` posts from off
        // the main actor.
        .onReceive(NotificationCenter.default.publisher(for: FilingSpendStore.didChange)
            .receive(on: DispatchQueue.main)) { _ in refreshSpend() }
        // The saved-suggestion count is asked SEPARATELY from the spend figures, and awaited.
        // Folding it into `refreshSpend` — which is what this did — put a decode of a file that
        // reaches ~12 MB at the entry cap on the main actor the moment this tab appeared. The two
        // spend reads are small `UserDefaults` blobs and stay where they are.
        .task { savedSuggestionCount = await syncManager?.filingVerdictCacheCount() ?? 0 }
        .sheet(isPresented: $showSpendHistory, onDismiss: refreshSpend) {
            FilingSpendHistorySheet()
        }
    }

    private func refreshSpend() {
        spendTotals = FilingSpendStore.totals()
        spendLast = FilingSpendStore.last()
    }
}

/// What the cloud pass has cost so far — total, tokens, scan count, and the most recent scan.
///
/// Four `SettingsRow`s until now, which was the wrong shape twice over: a `SettingsRow` reads as
/// "setting: value" and these set nothing, and four of them in a row put 4 × ~20pt of stacked
/// label/value between the caps and the buttons that act on them. As a strip the same four facts
/// read as one readout and cost one row's height.
///
/// A separate view rather than inline so the "no scans yet" case has somewhere to be stated once:
/// with `scans == 0` every figure is a zero, and four zeroes read as a broken control rather than
/// as an untouched one.
struct FilingSpendReadout: View {
    let totals: FilingSpendTotals
    let last: FilingSpendEntry?

    var body: some View {
        if totals.scans == 0 {
            Text("No cloud refines yet — nothing has been spent.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 18) {
                figure("Total spent", FilingSpendFormat.cost(totals.costUSD))
                figure("Tokens", FilingSpendFormat.tokens(totals.tokens))
                figure("Cloud refines", "\(totals.scans)")
                if let last {
                    figure("Last refine",
                           "\(FilingSpendFormat.model(last.model)) · \(FilingSpendFormat.files(last.fileCount)) · \(FilingSpendFormat.cost(last.estimatedCostUSD))")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A label over its value. `.monospacedDigit()` on the value so the four figures don't shift
    /// their neighbours as they grow — the strip is refreshed live while a refine runs.
    @ViewBuilder
    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            // No `.fixedSize(horizontal: false, vertical: true)` here, deliberately — it was
            // written in by analogy with `SettingsSection`'s caption and it does nothing. That
            // caption needs it because it is a `Text` inside a stack with `maxWidth: .infinity`,
            // which reports a one-line ideal height and clips. A figure in this strip is inside a
            // column the `HStack` proposes a real width to, so it already wraps; rendered at the
            // narrowest column the sheet can offer, with and without, the two are pixel-identical.
            Text(value)
                .scaledFont(.callout)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - People

/// The household Organize files for.
///
/// A tab rather than the section it was, because it is a ROSTER and not a preference: it has rows
/// with their own facts and veto counts, an overview of what the set governs across the tree, a
/// name-suggestion queue, a tester, and an editor sheet. That is the shape `ProvidersSettingsTab`
/// has — a list of things the user maintains — and none of it is what a `SettingsSection` is for.
/// It also outgrew its host: as Organize's fifth section it sat below a long tab, so the roster
/// was the part of Settings you had to scroll furthest to reach and the part most likely to need
/// editing.
struct PeopleSettingsTab: View {
    /// Reaches the people store, the folder profile, the filing memory and the veto log — four
    /// engine-side things, which is another sign this was never a settings section. Optional for
    /// the same reason every other tab's is.
    let syncManager: FileSyncManager?

    var body: some View {
        SettingsPage {
            SettingsSection(
                caption: "Who your documents belong to — the household Organize files for. It uses these names for two things: keeping one person’s document out of another’s folder, and choosing between folders that differ only by person (School/Aditi beside School/Divit). Names are matched longest-first, so “Aditi Abhishek” reads as Aditi alone rather than as two people — which matters when a first name is also somebody else’s surname. Add each person’s full names as documents print them; that is what makes a shared surname attributable. Nothing here leaves your Mac, and no document text is kept — only the names you add here."
            ) {
                if let store = syncManager?.filingPeopleStore,
                   let vetoLog = syncManager?.filingPersonVetoLog {
                    PeopleList(store: store,
                               profile: syncManager?.filingFolderProfile,
                               memory: syncManager?.filingMemory,
                               // The tree the profile describes. Absent until a scan has named it,
                               // which is also when its folder paths mean anything.
                               providerRoot: syncManager?.filingLastProviderRoot
                                   .map { URL(fileURLWithPath: $0) },
                               vetoLog: vetoLog)
                } else {
                    // No engine attached (tests, previews) — say so rather than leaving the caption
                    // over a void, and never offer an Add button that would write nowhere.
                    PeopleList.noStoreNote
                }
            }
        }
    }
}

/// The kept-names rows inside the Organize tab: one name per entry with a remove button, plus
/// Clear All — the inventory of "I meant that name" decisions, which until now could only be read
/// back by walking your files. A kept name draws no badge, so there was nothing on screen leading
/// anywhere; this is the only place the whole set is visible at once.
///
/// Split out so it can observe ``KeptNamesStore`` directly. `FileSyncManager` holds the store
/// behind a plain `var`, not a `@Published` one, so a view watching only the manager does not
/// repaint when the set changes — the manager's `keptNamesStore` didSet sends `objectWillChange`
/// by hand for exactly that reason, and this view does not rely on it.
///
/// Internal rather than `private`, unlike its `IgnoredItemsList` neighbour, so the tests can call
/// `remove(_:)` and `clearAll()` — the two methods the buttons call — against a real store on an
/// injected defaults suite. Nothing else constructs it.
struct KeptNamesList: View {
    @ObservedObject var store: KeptNamesStore

    var body: some View {
        if store.names.isEmpty {
            Self.nothingKeptNote
        } else {
            ForEach(store.sortedNames, id: \.self) { name in
                HStack {
                    KeptNameLabel(name: name)
                    Spacer()
                    Button {
                        remove(name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .hoverInk()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Report “\(name)” again — here, on its row, and in Organize")
                }
            }
            HStack {
                Spacer()
                Button("Clear All", role: .destructive, action: clearAll)
                    .controlSize(.small)
            }
        }
    }

    /// Withdraw one keep. Straight to the store, exactly as the row menu's "Stop Allowing This
    /// Name" does: the store is the single mutation point, and `FileSyncManager` subscribes to it
    /// for the announcement and the `riskyNames` reconciliation. Routing this through a manager
    /// method instead would be a second door onto the same latch.
    func remove(_ name: String) { store.stopKeeping(name) }

    /// Withdraw every keep. One store call rather than a loop over `remove(_:)`, so the manager
    /// re-filters its finding once.
    func clearAll() { store.stopKeepingAll() }

    /// Shown by an empty store, and by a tab built without an engine attached.
    static var nothingKeptNote: some View {
        Text("No kept names. Right-click a file with a flagged name and choose Always Allow This Name to keep it.")
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
    }
}

/// The household Organize files for — one row per person, each editable, each showing what the
/// engine actually knows about them.
///
/// **A list of names was not enough, and the reason is worth keeping.** The first version printed
/// six names and nothing else: it did not say what the section was for, what any of it did, or how
/// to change it — so a rule that can silently refuse a filing suggestion, on the grounds that a
/// document names the wrong person, was inspectable only in the sense that the names were visible.
/// Each row now leads with what that person's record *buys*: the name forms matched against a
/// document, how many folders in the tree are theirs, how many documents are already filed in them,
/// and a warning when every word they answer to is shared with somebody else — the state that makes
/// adding a full name worth doing.
///
/// `@ObservedObject` on the store, unlike the value this used to take: the roster is now written
/// from this view, and a list that did not observe its own edits would need a relaunch to show them.
struct PeopleList: View {
    @ObservedObject var store: PeopleStore
    let profile: FolderProfile?
    let memory: FilingMemory?
    /// The provider root the profile's relative paths hang off — needed to read the folders the
    /// suggestions are learned from. nil hides the action rather than reading the wrong tree.
    let providerRoot: URL?
    /// What the cross-person rule has refused. Optional: with no engine there is nothing to report,
    /// and an empty log is the ordinary state of a machine that has not filed anything yet.
    @ObservedObject var vetoLog: PersonVetoLog

    /// Which person is open in the editor. `nil` closes it; a person with an empty id is the
    /// "add" case, the same sheet doing both jobs.
    @State private var editing: Person?
    @State private var confirmingRemoval: Person?
    /// Name forms found in the tree that nobody has recorded. Empty until asked for — reading a few
    /// hundred folders is not something to do because a settings tab appeared.
    @State private var suggestions: [PersonNameSuggestion] = []
    @State private var isLooking = false
    @State private var hasLooked = false

    var body: some View {
        // Said before the list, because everything below it is a seed rather than the household —
        // and because the edits the list offers will not be written while this is true. Without it
        // the refusal in `PeopleStore.save()` is a change that appears to work and does nothing.
        if store.rosterIsUnreadable {
            Self.unreadableRosterNote
        } else if !store.repeatedRosterIds.isEmpty {
            // Its own note rather than a shared "read-only" one: the two refusals mean different
            // things to the person reading them. Above, the list is a guess. Here it is their real
            // household with a record missing, and the sentence has to name which id so they can go
            // and find it — the file is the only place the dropped record still exists.
            Self.repeatedIdRosterNote(store.repeatedRosterIds)
        }
        if store.people.isEmpty {
            Self.emptyRosterNote
        } else {
            ForEach(store.people) { person in
                PersonRow(facts: facts(for: person), person: person,
                          preventedCount: vetoLog.count(namedPerson: person.id),
                          lastPrevented: vetoLog.mostRecent(namedPerson: person.id),
                          onEdit: { editing = person },
                          onRemove: { confirmingRemoval = person })
            }
            // What the roster governs across the whole tree, and where it does not reach. Both are
            // facts about the SET, so neither belongs on a row.
            PeopleOverviewRow(overview: overview, store: store)
            ForEach(suggestions) { suggestion in
                PersonSuggestionRow(suggestion: suggestion,
                                    personName: store.person(id: suggestion.personId)?.displayName
                                        ?? suggestion.personId,
                                    onAccept: {
                                        store.acceptSuggestion(suggestion)
                                        suggestions.removeAll { $0.id == suggestion.id }
                                    },
                                    onDismiss: {
                                        store.dismissSuggestion(suggestion)
                                        suggestions.removeAll { $0.id == suggestion.id }
                                    })
            }
            if hasLooked, suggestions.isEmpty {
                Label("No new names in your filed documents — every form they use is recorded.",
                      systemImage: "checkmark.circle")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            PeopleTester(registry: store.registry, factsById: allFacts)
        }
        HStack(spacing: 10) {
            Button {
                editing = Person(id: "", displayName: "")
            } label: {
                Label("Add Person…", systemImage: "plus")
            }
            .controlSize(.small)
            if profile != nil, !store.people.isEmpty {
                Button(action: look) {
                    if isLooking {
                        Text("Reading…")
                    } else {
                        Label("Look for names", systemImage: "sparkle.magnifyingglass")
                    }
                }
                .controlSize(.small)
                .disabled(isLooking)
                .help("Reads the file names already in each person's folders and offers any name "
                      + "form they use that is not recorded yet. Nothing is changed without asking.")
            }
            Spacer()
            Text(sourceNote)
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
        .sheet(item: $editing) { person in
            PersonEditor(person: person,
                         isNew: person.id.isEmpty,
                         roster: store.people,
                         onSave: { edited in
                             if person.id.isEmpty {
                                 store.add(displayName: edited.displayName,
                                           relationship: edited.relationship,
                                           fullNames: edited.fullNames,
                                           aliases: edited.aliases)
                             } else {
                                 store.update(edited)
                             }
                             editing = nil
                         },
                         onCancel: { editing = nil })
        }
        .alert("Remove \(confirmingRemoval?.displayName ?? "")?",
               isPresented: Binding(get: { confirmingRemoval != nil },
                                    set: { if !$0 { confirmingRemoval = nil } })) {
            Button("Remove", role: .destructive) {
                if let p = confirmingRemoval { store.remove(id: p.id) }
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: {
            // Says what removal does and — more usefully — what it does not. Nobody should have to
            // guess whether this touches their files.
            Text("Their folders and files are left exactly as they are. Organize will stop "
                 + "recognising documents that name them, so it will no longer keep those documents "
                 + "out of other people's folders.")
        }
    }

    /// Everything known about one person, computed in `Sync` so the claim this view makes is
    /// testable without a window.
    private func facts(for person: Person) -> PersonFilingFacts {
        PersonFilingFacts.make(for: person, registry: store.registry,
                               profile: profile, memory: memory)
    }

    /// Reads the person folders off the main actor and publishes what it learned.
    ///
    /// Detached because this is a few hundred directory listings: small, but not small enough to
    /// spend on the actor that is drawing the window.
    private func look() {
        guard let profile, let root = providerRoot else { return }
        isLooking = true
        let registry = store.registry
        let dismissed = store.dismissedSuggestions
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                PeopleNameScanner.suggestions(registry: registry, profile: profile, root: root,
                                              dismissed: dismissed)
            }.value
            suggestions = found
            hasLooked = true
            isLooking = false
        }
    }

    /// Keyed tolerantly. `Dictionary(uniqueKeysWithValues:)` traps on a duplicate key, so a
    /// copy-pasted person block whose id was not changed crashed the app the moment this pane
    /// rendered, on the main actor — `people.json` is hand-edited and nothing rejected a repeat.
    ///
    /// **Nothing can deliver one here any more, and the keying stays regardless.**
    /// ``PersonRegistry`` collapses a repeated id to a single record on load, so `store.people` is
    /// unique by construction and this can no longer fire. It is kept because it is what the trap
    /// would come back through if that collapse ever regressed — and a guard removed for being
    /// unreachable is one that goes missing at exactly the moment it becomes reachable again.
    /// `theFactsMapStaysTolerantOfARepeatedKey` pins it, since no behavioural test can reach it.
    ///
    /// Last wins, which is the collapse's own rule and ``FolderSurveyBuilder``'s over the same file.
    private var allFacts: [String: PersonFilingFacts] {
        Dictionary(store.people.map { ($0.id, facts(for: $0)) }, uniquingKeysWith: { _, latest in latest })
    }

    private var overview: PeopleOverview {
        PeopleOverview.make(registry: store.registry, profile: profile, memory: memory)
    }

    private var sourceNote: String {
        store.source == .file
            ? "Saved in people.json"
            : "Suggested from your folder names — edit anyone to make it yours"
    }

    /// Shown when `people.json` is on disk but unreadable. It names the file and says plainly that
    /// edits will not save — the alternative is a roster that looks ordinary, edits that appear to
    /// take, and a real household quietly replaced by folder-name guesses.
    static var unreadableRosterNote: some View {
        Label {
            Text("The people file couldn’t be read, so this list is guessed from folder names. Edits won’t be saved. Fix people.json and restart SyncCloud — ~/sync-cloud.log says what went wrong.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .scaledFont(.callout)
        .foregroundStyle(.secondary)
    }

    /// Shown when `people.json` lists an id more than once: the list below is one person short of
    /// the file, and edits are held back so the write cannot make that permanent.
    ///
    /// Names the ids, because the dropped record exists nowhere else — the app has already stopped
    /// showing it, and a message that said only "a duplicate" would leave the user searching a file
    /// for something they cannot see.
    static func repeatedIdRosterNote(_ ids: [String]) -> some View {
        Label {
            Text(ids.count == 1
                 ? "people.json lists “\(ids[0])” more than once, so only its last entry is in use here. Edits won’t be saved, because saving would delete the others. Give each person a unique id in people.json and restart SyncCloud."
                 : "people.json lists these ids more than once — \(ids.joined(separator: ", ")) — so only the last entry of each is in use here. Edits won’t be saved, because saving would delete the others. Give each person a unique id in people.json and restart SyncCloud.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .scaledFont(.callout)
        .foregroundStyle(.secondary)
    }

    /// Shown when the roster is empty but editable — an invitation, not an error.
    static var emptyRosterNote: some View {
        Text("No people yet. Add the people whose documents you file — yourself, family — and Organize will stop mixing up whose document is whose.")
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
    }

    /// Shown when there is no engine behind the tab at all (tests, previews).
    static var noStoreNote: some View {
        Text("People are available once a filing profile is loaded.")
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
    }
}

/// One person: who they are, what the engine matches them on, and what that is worth in this tree.
///
/// The three lines are deliberately ordered by what a reader wants first — identity, then the
/// evidence, then the caveat. The caveat line is the only tinted one, because a name shared with
/// somebody else is the single fact on this screen that can change an outcome.
private struct PersonRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let facts: PersonFilingFacts
    let person: Person
    let preventedCount: Int
    let lastPrevented: PersonVetoEvent?
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PersonInitials(person: person)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(person.displayName).scaledFont(.callout).fontWeight(.medium)
                    if let relationship = person.relationship {
                        Text(relationship).scaledFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(matchedLine).scaledFont(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !knowledgeLine.isEmpty {
                    Text(knowledgeLine).scaledFont(.subheadline).foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if preventedCount > 0 {
                    Text(preventedLine).scaledFont(.subheadline)
                        .foregroundStyle(SemanticColor.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caveat = caveatLine {
                    Text(caveat).scaledFont(.subheadline)
                        .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.caution))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Edit", action: onEdit).controlSize(.small)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").hoverInk()
            }
            .buttonStyle(.hoverAffordance(.inline))
            .help("Remove \(person.displayName) from the household")
        }
        .padding(.vertical, 2)
        .help(tooltip)
    }

    /// The shared-word detail, which is real but not a problem — so it lives here rather than on a
    /// line of its own. Every member of this household shares a word with somebody; a row that said
    /// so in amber said it seven times out of seven and meant nothing.
    private var tooltip: String {
        var parts = [matchedLine]
        if !facts.uniqueWords.isEmpty {
            parts.append("Theirs alone: " + facts.uniqueWords.joined(separator: ", ") + ".")
        }
        if !facts.sharedWords.isEmpty {
            parts.append("Shared with the rest of the household: " + facts.sharedSummary + ".")
        }
        return parts.joined(separator: " ")
    }

    /// The forms a document is matched against, longest first — which is the order they are tried
    /// in, so the line doubles as an explanation of precedence.
    private var matchedLine: String {
        facts.matchedForms.isEmpty ? person.displayName
                                   : "Matches " + facts.matchedForms.joined(separator: " · ")
    }


    /// **The only line here that reports the rule doing something**, rather than describing what is
    /// known. It stays absent at zero: "prevented 0" would be a boast about nothing, and this
    /// section already has enough to read.
    private var preventedLine: String {
        let count = preventedCount == 1 ? "1 document" : "\(preventedCount) documents"
        guard let last = lastPrevented else { return "Kept \(count) out of other folders" }
        return "Kept \(count) out of other folders — last “\(last.fileName)”"
    }

    /// What the record is worth in this tree: how much, and **where**.
    ///
    /// One line rather than two. A separate areas line repeated the folder count back in another
    /// form — "Finance 1" above "1 folder is theirs" — which is the same fact twice. The totals
    /// answer "how much", the area names answer "about what", and three names is where a real
    /// record (nine areas) stops being a summary.
    ///
    /// Omitted entirely when nothing has been surveyed: "0 folders" on a machine with no profile
    /// reads as a fault rather than as an absence.
    private var knowledgeLine: String {
        guard facts.folderCount > 0 else { return "" }
        var out = facts.folderCount == 1 ? "1 folder" : "\(facts.folderCount) folders"
        if facts.filedDocuments > 0 {
            out += facts.filedDocuments == 1 ? " · 1 document" : " · \(facts.filedDocuments) documents"
        }
        guard !facts.areas.isEmpty else { return out }
        let names = facts.areas.prefix(3).map(\.name)
        let rest = facts.areas.count - names.count
        return out + " · " + names.joined(separator: ", ") + (rest > 0 ? " +\(rest) more" : "")
    }

    /// The one line that can change an outcome — and it is shown **only when there is one**.
    ///
    /// A document naming this person cannot be attributed to them: every word they answer to
    /// belongs to somebody else here as well, and they have no multi-word form for the matcher to
    /// find as a phrase. That is actionable, and rare. Merely *sharing* a word is neither.
    private var caveatLine: String? {
        guard !facts.isAttributable else { return nil }
        let shared = facts.sharedWords.isEmpty
            ? "Nothing names them yet"
            : "Nothing names them yet: " + facts.sharedSummary
        return shared + " — add a full name as documents print it"
    }
}

/// A name form the documents keep using that nobody has recorded — offered, never applied.
///
/// **The evidence is the point.** "Add this?" with no reason is a request to trust the app about
/// somebody's name; the count and a real filename let the user decide in a second, and decide
/// correctly when the answer is no — a wedding folder naming a couple produces a form that reads
/// exactly like a name and is not one.
struct PersonSuggestionRow: View {
    let suggestion: PersonNameSuggestion
    let personName: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(suggestion.form)” — another name for \(personName)?")
                    .scaledFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(suggestion.occurrences) of their filed documents use it, "
                     + "including “\(suggestion.exampleFile)”")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Add", action: onAccept).controlSize(.small)
            Button("Not a name", action: onDismiss).controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

/// A person's initials in a tinted disc. Identity at a glance, and the one thing on the row that
/// stays legible when the text is scaled up and everything else wraps.
private struct PersonInitials: View {
    let person: Person

    var body: some View {
        Text(initials)
            .scaledFont(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(tint.gradient))
            .accessibilityHidden(true)
    }

    /// Two letters of the **display name**, not initials of the full name.
    ///
    /// `AG` for Abhishek Girish and `AG` for Anuraag Girish is two identical discs in one list —
    /// rendered and seen. The display name is what the row is headed by and what the folders are
    /// called, so `Ab` and `An` track what the reader is actually looking at.
    private var initials: String {
        let name = PersonRegistry.words(person.displayName).first ?? person.displayName
        return name.prefix(2).capitalized
    }

    /// Derived from the id, so a person keeps their colour across renames and relaunches — a
    /// stable colour is what makes the disc worth having at all.
    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo]
        var hash = 5381
        for byte in person.id.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }
}

/// A kept name with its invisible characters made visible — an affix space as "␣", a zero-width
/// scalar as "◌", both tinted.
///
/// Not a plain `Text`: every name in this list is here *because* something about it is risky, and a
/// whole class of those offences is invisible in a proportional face. "report " and "report" would
/// render identically, in the one view whose entire job is telling the user what they kept. The
/// rule is ``InvisibleNameMarking``, shared with the Rename lens's card so the two cannot disagree
/// about how many trailing spaces a name has.
private struct KeptNameLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(InvisibleNameMarking.cells(for: name).enumerated()), id: \.offset) { _, cell in
                if cell.isMarker {
                    // Caution, matching the Rename lens's markers and the risky-names pill — the
                    // whole risky-name vocabulary sits in one tier.
                    Text(cell.glyph)
                        .foregroundStyle(SemanticColor.caution)
                        .background(SemanticColor.caution.opacity(PillVariant.fillOpacity))
                } else {
                    Text(cell.glyph)
                }
            }
        }
        .scaledFont(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .help(name)
    }
}

/// The full cloud-Filing spend history as a sheet (Settings' copy — FileExplorer has its own in
/// the Organize workspace; both read the shared FilingSpendStore).
struct FilingSpendHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FilingSpendEntry] = []
    @State private var totals = FilingSpendTotals()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // "Cloud AI", not "Cloud Filing": the workspace this sheet was named for is
                // Organize now, and the lens it reports on is To File. A twin of this header
                // lives in `FileExplorer`'s `FilingSpendHistoryView` and has to say the same.
                Text("Cloud AI Spend").scaledFont(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).shortcutKeycap("⏎")
            }
            .padding()
            Divider()
            HStack(spacing: 24) {
                stat(FilingSpendFormat.cost(totals.costUSD), "total")
                stat(FilingSpendFormat.tokens(totals.tokens), "tokens")
                stat("\(totals.scans)", "cloud refines")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            Divider()
            if entries.isEmpty {
                EmptyStateView(
                    icon: "cloud",
                    title: "No cloud refines yet",
                    layout: .compact
                )
            } else {
                List(entries.reversed()) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened)).scaledFont(.system(size: 12))
                            Text("\(FilingSpendFormat.model(entry.model)) · \(FilingSpendFormat.files(entry.fileCount)) · placed \(entry.placedCount)")
                                .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(FilingSpendFormat.cost(entry.estimatedCostUSD)).scaledFont(.system(size: 12, weight: .semibold)).monospacedDigit()
                            Text(FilingSpendFormat.tokens(entry.totalTokens)).scaledFont(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 540, height: 440)
        .onAppear {
            entries = FilingSpendStore.entries()
            totals = FilingSpendStore.totals()
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).scaledFont(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).scaledFont(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Advanced

/// Logging, maintenance, and the settings reset — the machinery that already existed in the
/// engine but had no user-facing surface.
struct AdvancedSettingsTab: View {
    let syncManager: FileSyncManager?
    let onResetAllSettings: (() -> Void)?

    @AppStorage(Logger.minimumLevelDefaultsKey) private var minimumLevelRaw: String = LogLevel.debug.rawValue
    /// Human-readable size of the log file, refreshed on appear and after Clear Log.
    @State private var logFileSizeText: String?
    /// Human-readable sizes of the two saved-scan-data files, or nil where there is no file. nil is
    /// what disables each Clear, so "None" and a live button cannot disagree.
    @State private var hashIndexSizeText: String?
    @State private var storageLensSizeText: String?

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Logging",
                caption: "The log rotates at 5 MB. Levels below the chosen one are skipped entirely."
            ) {
                SettingsRow("Log level") {
                    Picker("Log level", selection: $minimumLevelRaw) {
                        Text("Debug (everything)").tag(LogLevel.debug.rawValue)
                        Text("Info").tag(LogLevel.info.rawValue)
                        Text("Warnings").tag(LogLevel.warning.rawValue)
                        Text("Errors only").tag(LogLevel.error.rawValue)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: minimumLevelRaw) { _, raw in
                        Logger.shared.minimumLevel = LogLevel(rawValue: raw) ?? .debug
                    }
                }

                SettingsRow("Log file") {
                    HStack(spacing: 8) {
                        if let logFileSizeText {
                            Text(logFileSizeText)
                                .foregroundStyle(.secondary)
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Logger.shared.logFileURL])
                        }
                        Button("Clear Log") {
                            Logger.shared.clearLogs()
                            Task { await refreshLogFileSize() }
                        }
                    }
                    .controlSize(.small)
                }
            }

            SettingsSection(
                "Maintenance",
                caption: "Interrupted copies can leave .tmp_ working files behind; they're moved to the Trash automatically once they're an hour old. Recovery backups (.rollback_) are never touched."
            ) {
                SettingsRow("Orphaned temporary files") {
                    Button("Sweep Now") {
                        syncManager?.sweepOrphanedTempArtifactsNow()
                    }
                    .controlSize(.small)
                    .disabled(syncManager == nil)
                }
            }

            // The two scan caches the app writes to Application Support that had no readout and no
            // way to clear them. Saved suggestions is the third and stays in Organize, where the
            // toggles that decide what it keys on live; these two belong beside the log file,
            // because what a user wants from them is "how much is this storing, and make it stop".
            //
            // Sizes rather than entry counts: a `stat` each, where a count would mean parsing the
            // largest file this app writes — on the main actor, on a tab appearing.
            SettingsSection(
                "Saved scan data",
                caption: "Kept so a rescan doesn't repeat work it already did. Clearing costs time on the next scan and nothing else — your files aren't affected, and neither are your saved suggestions (Organize)."
            ) {
                SettingsRow("File digests") {
                    HStack(spacing: 8) {
                        Text(hashIndexSizeText ?? "None")
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            Task {
                                // **Said before it happens.** What this deletes is derived and
                                // recomputable, which is why the button is safe — but it is also
                                // why its effect surfaces much later and somewhere else: a cold
                                // duplicate scan that reads every byte again, and a launch line
                                // reporting "0 digest(s) reloaded". Without this the log offers
                                // nothing to connect either back to a deliberate act, and the
                                // deletion itself is silent (`ContentHashIndexStore` logs only
                                // the failure to delete).
                                Logger.shared.info("User cleared the saved file digests")
                                await ContentHashCache.forgetAllPersistedIndexes()
                                // The barrier is a blocking `writeQueue.sync`, and this Task runs
                                // on the main actor — parked behind a queued multi-megabyte index
                                // write (a Verify save that just fired, say) it is a beachball.
                                // Detached, the wait happens where blocking is free.
                                await Task.detached(priority: .utility) {
                                    ContentHashIndexStore.waitForPendingWrites()
                                }.value
                                await refreshSavedScanData()
                            }
                        }
                        .disabled(hashIndexSizeText == nil)
                    }
                    .controlSize(.small)
                }
                .help("Checksums of files Duplicates and Verify have already read, so unchanged files aren't read again. Clearing means the next scan re-reads them.")

                SettingsRow("Saved Storage reports") {
                    HStack(spacing: 8) {
                        Text(storageLensSizeText ?? "None")
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            // Same reason as the digests' Clear above: the next Storage panel
                            // opening empty is the only visible trace otherwise.
                            Logger.shared.info("User cleared the saved Storage reports")
                            syncManager?.forgetStoredStorageLens()
                            Task {
                                // Off the main actor for the same reason as the digests' Clear
                                // above — the barrier blocks on the store's write queue.
                                await Task.detached(priority: .utility) {
                                    StorageLensStore.waitForPendingWrites()
                                }.value
                                await refreshSavedScanData()
                            }
                        }
                        .disabled(storageLensSizeText == nil || syncManager == nil)
                    }
                    .controlSize(.small)
                }
                .help("The last Storage analysis for each folder, shown while a fresh one runs. Clearing means Storage starts from an empty panel again.")
            }

            if let onResetAllSettings {
                SettingsSection(
                    caption: "Restores defaults for appearance, sync behavior, and source names and paths, and clears the folders you added as sources. Your files aren't affected."
                ) {
                    Button("Reset All Settings…", role: .destructive) {
                        confirmReset(onResetAllSettings)
                    }
                }
            }
        }
        .task { await refreshLogFileSize() }
        .task { await refreshSavedScanData() }
    }

    /// Stats the saved-scan-data files. The digest sizes are asked of the cache actors rather than
    /// of the store, because only an actor knows whether persistence was enabled at all — a
    /// location the app injects and tests never do. "File digests" is every persisted digest index
    /// summed (content hashes and document fingerprints), not just the first one: they are one
    /// answer to "how much is this storing, and make it stop", and a Clear that left half of it
    /// behind would contradict this section's own caption.
    private func refreshSavedScanData() async {
        let hashBytes = await ContentHashCache.totalPersistedSizeOnDisk()
        let storageBytes = syncManager?.storedStorageLensSizeOnDisk()
        // Zero-byte files read as "None": a store that has been cleared leaves an empty payload
        // behind in the Storage case, and offering Clear for 0 bytes is offering nothing.
        hashIndexSizeText = Self.sizeText(hashBytes)
        storageLensSizeText = Self.sizeText(storageBytes)
    }

    private static func sizeText(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Confirmation ahead of the defaults wipe; Cancel is the default button (Return must
    /// not reset, same convention as the permanent-delete alert).
    private func confirmReset(_ reset: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all settings?"
        // Names the folder list explicitly. "Files on disk are not affected" is true and used to be
        // the whole of the reassurance, which read as "nothing you care about is lost" while the
        // curated list of folder sources went with the defaults domain.
        alert.informativeText = "Appearance, sync behavior, ignored items, and source names and paths return to their defaults, and any folders you added as sources are removed from the list. Files on disk are not affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if let resetButton = alert.buttons.first {
            resetButton.hasDestructiveAction = true
            resetButton.keyEquivalent = ""
        }
        alert.buttons.last?.keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn {
            reset()
        }
    }

    /// Stats the log file off the main actor (flushing buffered writes first so the number
    /// reflects everything logged).
    private func refreshLogFileSize() async {
        let url = Logger.shared.logFileURL
        let logger = Logger.shared
        let bytes = await Task.detached(priority: .utility) { () -> Int? in
            logger.flushToDisk()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.intValue
        }.value
        logFileSizeText = bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}

extension SettingsView.SettingsTab {

    /// Where a stored `settingsSelectedTab` resolves to, including when it resolves to nothing.
    ///
    /// The launch read lives in `MacApp/ContentView.swift`, which belongs to no SPM package — only
    /// the app target compiles it — so the fallback there was reachable by no test at all. It
    /// matters more here than it looks: the stored value is written by past builds and by the
    /// GUI-verification recipe's `defaults`
    /// call, so it is the one input to Settings that is genuinely outside the app's control. A
    /// force-unwrap or a `!` added there would crash on launch for anyone whose stored tab had
    /// been retired, and nothing in the repo would have said so first.
    ///
    /// Falls back rather than trapping, and the fallback is Appearance because it is the tab that
    /// depends on nothing — no engine, no provider list, no roster — so it is safe to land on
    /// whatever state the app is in.
    public static func resolvingStored(_ raw: String?) -> Self {
        guard let raw, let tab = Self(rawValue: raw) else { return .appearance }
        return tab
    }
}
