import Foundation
import UniformTypeIdentifiers
import Sync

/// **An image dropped on a note, or pasted into it, saved where the note can link to it** (TE56,
/// decision O: one `Images` folder in the note's folder, shared by every note there).
///
/// These folders are synced to somebody's cloud storage, so the rules are about never losing a
/// file there: nothing is ever overwritten (``EditorFileStore/createNew(_:atPath:)`` refuses in the
/// same step that would replace), a dropped file is copied and never moved, and every refusal is
/// decided BEFORE anything is written, so a refusal leaves the disk exactly as it was.
public enum EditorImageImport {

    /// What arrived.
    public enum Source: Equatable, Sendable {
        /// A file dropped from Finder, by path.
        case file(String)
        /// Image data from the clipboard — a screenshot taken with ⌃⇧⌘4 — already PNG.
        case png(Data)
    }

    /// What happened, for the host: the files it now owes the panes a re-read for, or why nothing
    /// was written.
    public enum Report: Equatable, Sendable {
        /// `files` were written (in order); `madeFolder` is the Images folder when this import made
        /// it. `linked` are the links inserted, which include an image already in the folder.
        /// `failed` says why an image after the last one linked was not saved — `nil` when all were.
        case wrote(files: [String], madeFolder: String?, linked: [String], failed: String? = nil)
        /// Nothing was written; the sentence says why, in the reader's words.
        case refused(String)
    }

    /// The folder's name. One word, capitalised as Finder's own folders are.
    public static let folderName = "Images"

    /// Whether `path` names an image file — by its type, the way Finder decides, so `.HEIC` and
    /// `.jpeg` count and a `.pdf` does not.
    public static func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// Writes `sources` into the Images folder beside `notePath`, and answers what to link.
    ///
    /// - Parameter linkedIn: the note's text. A number it still LINKS is never given out again, even
    ///   when its file has gone — a new picture would appear in the old one's place.
    /// - Returns: `.refused` with nothing on disk changed, or `.wrote` with the links to insert —
    ///   `Images/<name>`, percent-encoded so a name with spaces is one portable CommonMark link.
    ///
    /// **Files written before a later one fails stay, and are linked** — undo here must never delete
    /// a file, and a file nothing links to is worse than one the note shows. An Images folder made
    /// for an import that then wrote nothing is taken away again, and only if it is still empty.
    public static func importImages(_ sources: [Source], forNote notePath: String, linkedIn noteText: String = "",
                                    isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
                                    isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) })
        -> Report {
        guard !sources.isEmpty else { return .refused("There was no image to add.") }
        let fileManager = FileManager.default
        let noteFolder = (notePath as NSString).deletingLastPathComponent
        // A dropped alias-by-symlink is copied as the file it points at — copying the link would put
        // a link to a photo elsewhere in this folder, not the photo.
        let sources = sources.map { source -> Source in
            guard case .file(let path) = source else { return source }
            return .file(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }

        // 1. The sources, before anything is touched.
        for case .file(let path) in sources {
            let name = (path as NSString).lastPathComponent
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return .refused("“\(name)” isn't there any more, so it couldn't be added.")
            }
            guard !isDirectory.boolValue else {
                return .refused("“\(name)” is a folder, not an image, so it couldn't be added.")
            }
            // **Refused, not fetched.** Copying a cloud-only file reads it, which downloads it —
            // on the main thread, for as long as the provider takes, and a provider that does not
            // answer hangs the window (`DatalessFolderReads`). The pane offers Download.
            guard !isCloudOnly(path) else {
                return .refused("“\(name)” is still in the cloud. Download it first, then drop it again.")
            }
        }

        // 2. The folder: the one already there, whatever its case, or a new one.
        let folder: (path: String, name: String, exists: Bool)
        switch imagesFolder(in: noteFolder, isCloudOnly: isCloudOnly) {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let found): folder = found
        }
        guard isWritable(folder.exists ? folder.path : noteFolder) else {
            return .refused(folder.exists
                ? "The \(folder.name) folder here can't be written to, so the image couldn't be added."
                : "This note's folder can't be written to, so the image couldn't be added.")
        }

        // 3. Names, from the note's — `Pasta-1.jpg` — counting on from the highest number in the
        // folder or in the note's own links. The stem is shortened ONCE, so every name and the
        // count read the same one.
        let stem = fittedStem(imageStem(forNote: notePath))
        let existing = folder.exists ? ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []) : []
        var number = max(highestNumber(for: stem, among: existing),
                         highestLinkedNumber(for: stem, folder: folder.name, in: noteText))

        var madeFolder: String?
        if !folder.exists {
            do {
                try fileManager.createDirectory(atPath: folder.path, withIntermediateDirectories: false)
                madeFolder = folder.path
            } catch {
                return .refused("The \(folder.name) folder couldn't be made here — \(error.localizedDescription)")
            }
        }

        var written: [String] = []
        var links: [String] = []
        var failure: String?
        let resolvedFolder = URL(fileURLWithPath: folder.path).resolvingSymlinksInPath().path
        for source in sources {
            // An image already in the folder is linked where it is — a second copy of it beside
            // itself is clutter in a synced folder, and nothing to protect.
            if case .file(let path) = source, folder.exists,
               (path as NSString).deletingLastPathComponent == resolvedFolder {
                links.append(link(folder: folder.name, file: (path as NSString).lastPathComponent))
                continue
            }
            let ext: String
            let label: String
            switch source {
            case .file(let path):
                ext = (path as NSString).pathExtension
                label = "“\((path as NSString).lastPathComponent)”"
            case .png:
                ext = "png"
                label = "The pasted image"
            }
            // A name taken between the listing and the write is refused by the write, not replaced;
            // the next number is tried. Bounded, so a folder that answers "taken" to everything ends.
            var landed: String?
            for _ in 0..<64 {
                number += 1
                let name = stem + "-\(number)" + (ext.isEmpty ? "" : ".\(ext)")
                let path = (folder.path as NSString).appendingPathComponent(name)
                do {
                    switch source {
                    case .file(let from): try EditorFileStore.createNew(copying: from, toPath: path)
                    case .png(let data): try EditorFileStore.createNew(data, atPath: path)
                    }
                    landed = name
                } catch is EditorFileStore.AlreadyExists {
                    continue
                } catch {
                    // **A failure AFTER the file landed is still a file that landed** — the door's
                    // read-back can fail once the move is done, and an image on disk that the note
                    // does not link is the worst of both.
                    if (try? fileManager.attributesOfItem(atPath: path)) != nil { landed = name }
                    failure = "\(label) couldn't be saved in \(folder.name) — \(error.localizedDescription)"
                }
                break
            }
            guard let landed else {
                failure = failure ?? "\(label) couldn't be saved in \(folder.name) — every name was taken."
                break
            }
            written.append((folder.path as NSString).appendingPathComponent(landed))
            links.append(link(folder: folder.name, file: landed))
            if failure != nil { break }
        }

        guard !links.isEmpty else {
            // Nothing landed: a folder made for this import goes again — `rmdir`, which removes only
            // an EMPTY folder, so nothing anybody put there can go with it.
            if let madeFolder, rmdir(madeFolder) != 0 {
                return .wrote(files: [], madeFolder: madeFolder, linked: [],
                              failed: failure ?? "The image couldn't be saved.")
            }
            return .refused(failure ?? "The image couldn't be saved.")
        }
        return .wrote(files: written, madeFolder: madeFolder, linked: links,
                      failed: links.count < sources.count || failure != nil
                          ? (failure ?? "Only \(links.count) of \(sources.count) images could be saved.")
                          : nil)
    }

    // MARK: - The rules, each on its own

    struct Refusal: Error, Equatable { var message: String }

    /// **The note folder's Images folder: the one there, in whatever case it was made, or where a new
    /// one would go.** Looked up by listing rather than by `fileExists`, so a folder made as
    /// `images` is found and linked by ITS name — on a case-insensitive disk `Images/x.png` would
    /// open it, and on GitHub or a case-sensitive volume it would not.
    static func imagesFolder(in noteFolder: String, isCloudOnly: (String) -> Bool)
        -> Result<(path: String, name: String, exists: Bool), Refusal> {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: noteFolder)) ?? []
        let name = entries.first { $0 == folderName }
            ?? entries.first { $0.caseInsensitiveCompare(folderName) == .orderedSame }
        guard let name else {
            return .success(((noteFolder as NSString).appendingPathComponent(folderName), folderName, false))
        }
        let path = (noteFolder as NSString).appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(Refusal(message: "There's a file called “\(name)” in this note's folder, so "
                + "the image has nowhere to go. Rename that file, then try again."))
        }
        // Through a symlink to where it leads: `isCloudOnly` reads the link itself, and the folder
        // it points at is the one that would be listed.
        guard !isCloudOnly(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) else {
            return .failure(Refusal(message: "The \(name) folder here is still in the cloud. Open it in "
                + "Finder so it downloads, then try again."))
        }
        return .success((path, name, true))
    }

    /// The note's name without its extension — what the images are called after. A leading dot
    /// would make every image hidden, so it is dropped; a name that is nothing else becomes "Image".
    static func imageStem(forNote notePath: String) -> String {
        let stem = ((notePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let visible = String(stem.drop { $0 == "." })
        return visible.isEmpty ? "Image" : visible
    }

    /// The highest `N` among names of the form `<stem>-N.<ext>`, any extension, any case — 0 when
    /// there are none.
    ///
    /// **The highest, not the first gap.** A note can still link `Pasta-1.jpg` after the file was
    /// deleted, and a new image given that name would quietly appear in its place. Digits only, and
    /// at most six of them: a name somebody wrote as `Pasta-99999999999999999999.png` is not a
    /// number this counts on from.
    static func highestNumber(for stem: String, among names: [String]) -> Int {
        let prefix = (stem + "-").lowercased()
        return names.reduce(0) { highest, name in
            let base = ((name as NSString).deletingPathExtension).lowercased()
            guard base.hasPrefix(prefix), !(name as NSString).pathExtension.isEmpty else { return highest }
            return max(highest, number(base.dropFirst(prefix.count)) ?? 0)
        }
    }

    /// The highest `N` the note's own text links as `<folder>/<stem>-N.…`, written either way —
    /// percent-encoded as Edit writes it, or plain inside `<…>`.
    static func highestLinkedNumber(for stem: String, folder: String, in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var highest = 0
        for spelling in Set([link(folder: folder, file: stem), folder + "/" + stem]) {
            let pattern = NSRegularExpression.escapedPattern(for: spelling + "-") + "([0-9]{1,6})\\."
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                highest = max(highest, Int(ns.substring(with: match.range(at: 1))) ?? 0)
            }
        }
        return highest
    }

    private static func number(_ digits: Substring) -> Int? {
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The stem shortened so that `<stem>-NNNNNN.<extension>` fits the 255-byte limit on a name
    /// for any extension up to 16 bytes — once, so the names and the count agree on it.
    static func fittedStem(_ stem: String) -> String {
        var fitted = stem
        while fitted.utf8.count > 255 - 24, !fitted.isEmpty { fitted.removeLast() }
        return fitted.isEmpty ? "Image" : fitted
    }

    /// `<stem>-N.<ext>`, the stem shortened to fit the 255-byte limit on a name.
    static func fittedName(stem: String, number: Int, ext: String) -> String {
        fittedStem(stem) + "-\(number)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// The link as it goes in the note: `Images/<name>`, each part percent-encoded down to letters,
    /// digits and `-._~` — portable CommonMark however the name is spelt, and what
    /// ``MarkdownImageSource`` decodes back to the file.
    static func link(folder: String, file: String) -> String {
        [folder, file].map { $0.addingPercentEncoding(withAllowedCharacters: linkSafe) ?? $0 }
            .joined(separator: "/")
    }

    private static let linkSafe: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()
}
