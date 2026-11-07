import Combine
import SwiftUI
import Testing
@testable import Sync
@testable import FileExplorer

/// Organize's narrowing survives a workspace switch, and the scan-start resets still clear it.
///
/// `LensWorkspaceView` sits inside one arm of `ContentView`'s layout switch, so leaving Organize
/// destroys it. Its state (match filter, parked query, unfolded sections, "freed this session", the
/// filed and dismissed flags) lives in ``LensWorkspaceSession``, held by `ContentView`, which is
/// mounted once per window. That makes the scan-start resets the only thing clearing it: an
/// omission from `DuplicateScanReset` shows a narrowing against results it was never aimed at.
@MainActor
@Suite struct OrganizeSessionPersistenceTests {

    // MARK: The session holds what the reader set

    /// State written into a session is still there in the session a later mount is handed: the view
    /// being rebuilt can't take the narrowing with it, because the narrowing is not in the view.
    @Test func aSessionKeepsEveryNarrowingAcrossAMount() {
        let session = LensWorkspaceSession()
        session.filter = .versions
        session.searchQueries[.duplicates] = "kind:pdf >5mb"
        session.searchExpandedLenses.insert(.duplicates)
        session.unfoldedSections.insert(.identical)
        session.reclaim.credit(4_096)
        session.filedThisSession = true
        session.dismissedThisSession = true

        // What a workspace switch does: the view goes, the session does not.
        let survivor = LensWorkspaceView.startingSession(session, seed: [:])

        #expect(survivor === session, "a host session was replaced rather than reused")
        #expect(survivor.filter == .versions)
        #expect(survivor.searchQueries[.duplicates] == "kind:pdf >5mb")
        #expect(survivor.searchExpandedLenses.contains(.duplicates))
        #expect(survivor.unfoldedSections.contains(.identical))
        #expect(survivor.reclaim.totalBytes == 4_096)
        #expect(survivor.filedThisSession)
        #expect(survivor.dismissedThisSession)
    }

    /// A caller with no session of its own gets a fresh one, as `@State` would. Every test that
    /// mounts this view to ask about something else relies on it.
    @Test func noHostSessionMeansPerMountState() {
        let first = LensWorkspaceView.startingSession(nil, seed: [:])
        first.filter = .versions
        let second = LensWorkspaceView.startingSession(nil, seed: [:])

        #expect(first !== second)
        #expect(second.filter == .all, "an unhosted mount inherited another mount's narrowing")
    }

    /// A nested `ObservableObject` does not publish through its parent, so the session must re-emit
    /// `automationsState`'s changes as its own. Without that, "Preview all" writes
    /// `viewingResults`, nobody hears it, and the lens keeps drawing the rule list until an
    /// unrelated publish. Nothing rendered would notice; removing the forwarding subscription must
    /// make this test fail.
    @Test func theSessionRepublishesTheAutomationsLensState() {
        let session = LensWorkspaceSession()
        var announcements = 0
        let token = session.objectWillChange.sink { _ in announcements += 1 }
        defer { token.cancel() }

        session.automationsState.viewingResults = true

        #expect(announcements == 1,
                "the session did not re-emit its automations state — 'Preview all' writes the flag and nothing observing the session hears it")
    }

    // MARK: The seed

    /// `initialSearchQueries` is the one way into a live query without typing, and SwiftUI can't be
    /// driven from a unit test, so it is what makes anything depending on a query testable.
    @Test func aSeededQueryReachesTheSession() {
        let session = LensWorkspaceView.startingSession(nil, seed: [.duplicates: "invoice"])
        #expect(session.searchQueries[.duplicates] == "invoice")
    }

    /// An empty seed may not clear a live query. The app passes no seed, so a seed applied anywhere
    /// but on first mount would wipe the parked query at the next publish, and a running scan
    /// publishes several times a second.
    @Test func anEmptySeedLeavesAParkedQueryAlone() {
        let session = LensWorkspaceSession()
        session.searchQueries[.duplicates] = "kind:pdf"

        let survivor = LensWorkspaceView.startingSession(session, seed: [:])

        #expect(survivor.searchQueries[.duplicates] == "kind:pdf",
                "the app's empty seed cleared a query the reader had typed")
    }

    // MARK: The resets, which now have nothing under them

    /// A new scan retires the previous scan's narrowing even when the session outlives the view.
    /// Driven through the same `inout` call the view makes: computed forwarders pass `inout` by
    /// get-modify-set, and one that read the session but wrote elsewhere would compile and silently
    /// drop the reset.
    @Test func aFreshScanRetiresTheNarrowingHeldInTheSession() {
        let session = LensWorkspaceSession()
        session.filter = .versions
        session.searchQueries[.duplicates] = "kind:pdf"
        session.reclaim.credit(8_192)

        DuplicateScanReset.duplicatesScanStarted(filter: &session.filter,
                                                 searchQuery: &session.searchQueries[.duplicates, default: ""],
                                                 reclaim: &session.reclaim)

        #expect(session.filter == .all,
                "a filter picked against the previous results survived into a new scan")
        #expect(session.searchQueries[.duplicates]?.isEmpty ?? true)
        #expect(session.reclaim.totalBytes == 0,
                "\"freed this session\" carried a previous scan's total")
    }

    /// The Organize-side scan-start reset still names every flag it has to. Scanned rather than
    /// driven: the assignments live in `.onChange(of: isSuggestingFiles)` inside a SwiftUI body,
    /// which a unit test can't fire. An omission would show a stale "All filed" over a scan that
    /// filed nothing. The `#require` is the positive control: a missing handler fails rather than
    /// passing on an empty search.
    @Test func theScanStartHandlerStillRetiresEveryOrganizeSessionFlag() throws {
        let source = try SourceText.fileExplorer("LensWorkspaceView.swift")
        let marker = try #require(source.range(of: ".onChange(of: syncManager.isSuggestingFiles)"),
                                  "the filing scan-start handler is gone — nothing retires the session flags")
        let handler = String(source[marker.lowerBound...].prefix(1_200))

        for cleared in ["filedThisSession = false",
                        "dismissedThisSession = false",
                        "pendingRememberPrompt = nil",
                        "pendingRuleOffer = nil"] {
            #expect(handler.contains(cleared),
                    "a fresh filing scan no longer clears `\(cleared)` — and the mount that used to hide that is gone")
        }
    }
}
