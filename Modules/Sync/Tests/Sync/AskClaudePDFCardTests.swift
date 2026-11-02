import Testing
import Foundation
@testable import Sync

/// **An Ask Claude PDF card's saved shape** (TE294 step 3): it round-trips through the chat's
/// JSON as it was, holds no field a password could be put in, and knows which card a newer one
/// replaces.
struct AskClaudePDFCardTests {

    private func card(_ action: AskClaudePDFCard.Action, _ paths: [String], state: AskClaudePDFCard.State = .offered)
    -> AskClaudePDFCard {
        AskClaudePDFCard(action: action, rows: paths.map {
            .init(path: $0, name: ($0 as NSString).lastPathComponent, folderLabel: "iCloud › Documents", bytes: 1200,
                  pageCount: 4, stamp: AskClaudeFileStamp(modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                          size: 1200, fileID: 42))
        }, options: .init(strength: .balanced, underMB: 5, pages: "3-5, 1", splitAt: [4, 9], mode: .lockToOpen,
                          name: "Trip (combined).pdf"), state: state,
           losses: ["Every page becomes a picture, so the copy’s text can’t be selected or searched."],
           written: [.init(path: "/d/A (compressed).pdf",
                           stamp: AskClaudeFileStamp(modifiedAt: Date(timeIntervalSince1970: 1_700_000_100), size: 300, fileID: 43),
                           bytes: 300, pageCount: 4)],
           message: "Saved “A (compressed).pdf”")
    }

    /// **Round-trips through the chat's JSON exactly**, every field set.
    @Test func roundTripsThroughTheChatsJSON() throws {
        let saved = card(.compress, ["/d/A.pdf", "/d/B.pdf"])
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(AskClaudePDFCard.self, from: data) == saved)
    }

    /// **No field of the saved card is a password's** — Protect's password lives in the card's
    /// field and nowhere else. Pinned on the encoded keys, so a field added later is seen here.
    @Test func savesNoPassword() throws {
        let data = try JSONEncoder().encode(card(.protect, ["/d/Return.pdf"]))
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for word in ["password", "secret", "passphrase"] {
            #expect(!text.contains("\"\(word)"), "a key named \(word) is saved: \(text)")
        }
    }

    /// **A newer card for the same tool on the same files replaces an open one** — never a card
    /// already run, nor one for other files or another tool.
    @Test func knowsWhichCardANewerOneReplaces() {
        let open = card(.compress, ["/d/A.pdf", "/d/B.pdf"])
        #expect(open.isReplaced(by: card(.compress, ["/d/B.pdf", "/d/A.pdf"])))
        #expect(!open.isReplaced(by: card(.compress, ["/d/A.pdf"])))
        #expect(!open.isReplaced(by: card(.rotate, ["/d/A.pdf", "/d/B.pdf"])))
        #expect(!card(.compress, ["/d/A.pdf"], state: .done).isReplaced(by: card(.compress, ["/d/A.pdf"])))
    }

    /// The title counts several files, and Combine counts its PDFs.
    @Test func titlesCountTheFiles() {
        #expect(card(.compress, ["/d/A.pdf"]).title == "Compress")
        #expect(card(.compress, ["/d/A.pdf", "/d/B.pdf", "/d/C.pdf"]).title == "Compress · 3 files")
        #expect(card(.combine, ["/d/A.pdf", "/d/B.pdf"]).title == "Combine 2 PDFs")
        #expect(card(.extract, ["/d/A.pdf"]).title == "Extract Pages")
    }

    /// Which tools take several files and which draw pages — what the runner and the card ask.
    @Test func knowsWhatEachToolTakes() {
        let several = AskClaudePDFCard.Action.allCases.filter(\.takesSeveral)
        #expect(several == [.saveAsPDF, .compress, .rotate, .cleanMetadata, .combine])
        let pages = AskClaudePDFCard.Action.allCases.filter(\.choosesPages)
        #expect(pages == [.extract, .deletePages, .reorder, .split])
    }
}
