import Combine
import SwiftUI
import Testing
@testable import Sync
@testable import FileExplorer

/// Organize's narrowing survives a workspace switch, and the scan-start resets still clear it.
/// Leaving Organize destroys `LensWorkspaceView`, so its state lives in ``LensWorkspaceSession``,
/// held by `ContentView`. That makes the scan-start resets the only thing clearing it: an omission
/// from `DuplicateScanReset` shows a narrowing against results it was never aimed at.
@MainActor
@Suite struct OrganizeSessionPersistenceTests {

    // MARK: The session holds what the reader set

/// State written into a session is still there for a later mount: the narrowing is not in the view.
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

/// A nested `ObservableObject` does not publish through its parent, so the session re-emits
/// `automationsState`'s changes, or "Preview all" goes unheard until an unrelated publish. Removing
/// the forwarding subscription must fail this.
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

/// `initialSearchQueries` is the one way into a live query without typing, so what makes anything
/// depending on a query testable.
    @Test func aSeededQueryReachesTheSession() {
        let session = LensWorkspaceView.startingSession(nil, seed: [.duplicates: "invoice"])
        #expect(session.searchQueries[.duplicates] == "invoice")
    }

    // MARK: The resets, which now have nothing under them

/// A new scan retires the previous narrowing even when the session outlives the view. Through the
/// same `inout` call the view makes: a forwarder that read the session but wrote elsewhere would
/// compile and silently drop the reset.
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

/// The Organize-side scan-start reset still names every flag it has to; scanned, because it lives
/// in an `.onChange` a unit test can't fire. An omission shows a stale "All filed". The `#require`
/// is the positive control.
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
