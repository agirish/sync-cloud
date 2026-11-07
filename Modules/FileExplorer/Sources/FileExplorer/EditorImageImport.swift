import Foundation
import UniformTypeIdentifiers
import Sync

/// An image dropped on a note, or pasted into it, saved where the note can link to it: one
/// `Images` folder in the note's folder, shared by every note there.
///
/// These folders sync to cloud storage, so the rules never lose a file: nothing is overwritten
/// (``EditorFileStore/createNew(_:atPath:)`` refuses in the same step that would replace), a dropped
/// file is copied, never moved, and every refusal is decided before anything is written.
public enum EditorImageImport {

    /// What arrived.
    enum Source: Equatable, Sendable {
        /// A file dropped from Finder, by path.
        case file(String)
        /// Image data from the clipboard (a screenshot, a picture copied in a browser) and the
        /// extension it is saved under: its own for a format kept as it is, else `png`
        /// (`PlainTextEditor.Coordinator.pastedImage(on:)`).
        case data(Data, extension: String)

        /// PNG data, such as a screenshot taken with ⌃⇧⌘4.
        static func png(_ data: Data) -> Source { .data(data, extension: "png") }
    }

    /// What happened, for the host: the files it now owes the panes a re-read for, or why nothing
    /// was written.
    public enum Report: Equatable, Sendable {
        /// `files` were written (in order); `madeFolder` is the Images folder when this import made
        /// it. `linked` are the links inserted, which include an image already in the folder.
        /// `failed` says why an image after the last one linked was not saved; `nil` when all were.
        case wrote(files: [String], madeFolder: String?, linked: [String], failed: String? = nil)
        /// Nothing was written; the sentence says why, in the reader's words.
        case refused(String)
    }

    /// The folder's name. One word, capitalised as Finder's own folders are.
    static let folderName = "Images"

    /// What the status line says after an import, or `nil` when nothing new was saved: where the
    /// images went, and whether a folder was made. Counts files written (an image already in the
    /// folder is only linked) and names the folder as Finder shows it.
    public static func notice(for report: Report) -> String? {
        guard case .wrote(let files, let madeFolder, _, _) = report, let first = files.first else { return nil }
        let folder = ((madeFolder ?? (first as NSString).deletingLastPathComponent) as NSString).lastPathComponent
        let what = files.count == 1 ? "“\((first as NSString).lastPathComponent)”" : "\(files.count) images"
        return madeFolder == nil ? "Saved \(what) in \(folder)" : "Made an \(folder) folder for \(what)"
    }

    /// Whether `path` names an image file, by its type as Finder decides, so `.HEIC` and `.jpeg`
    /// count and a `.pdf` does not.
    static func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// Writes `sources` into the Images folder beside `notePath`, and answers what to link.
    ///
    /// - Parameter linkedIn: the note's text. A number it still links is never given out again,
    ///   even when its file has gone, or a new picture would appear in the old one's place.
    /// - Returns: `.refused` with nothing on disk changed, or `.wrote` with the links to insert:
    ///   `Images/<name>`, percent-encoded so a name with spaces is one portable CommonMark link.
    ///
    /// Files written before a later one fails stay, and are linked: undo here must never delete a
    /// file, and an unlinked file is worse than one the note shows. An Images folder made for an
    /// import that wrote nothing is removed again, only if still empty.
    static func importImages(_ sources: [Source], forNote notePath: String, linkedIn noteText: String = "",
                                    isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
                                    isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) })
        -> Report {
        guard !sources.isEmpty else { return .refused("There was no image to add.") }
        let fileManager = FileManager.default
        // The note as it is on disk: through a symlink, the file the link leads to.
        let notePath = noteFile(notePath)
        let noteFolder = (notePath as NSString).deletingLastPathComponent
        // A dropped symlink is copied as the file it points at; copying the link would put a link
        // to a photo elsewhere in this folder, not the photo.
        let sources = sources.map { source -> Source in
            guard case .file(let path) = source else { return source }
            return .file(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }

        // 1. The sources, before anything is touched.
        for case .file(let path) in sources {
            let name = (path as NSString).lastPathComponent
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return .refused("“\(name)” isn’t there any more, so it couldn’t be added.")
            }
            guard !isDirectory.boolValue else {
                return .refused("“\(name)” is a folder, not an image, so it couldn’t be added.")
            }
            // Refused, not fetched: copying a cloud-only file downloads it on the main thread, and
            // a provider that doesn't answer hangs the window (`DatalessFolderReads`). The pane
            // offers Download.
            guard !isCloudOnly(MaterializationStatus.linkTarget(of: path)) else {
                return .refused("“\(name)” is still in the cloud. Download it first, then add it again.")
            }
            // Asked here, so an unreadable photo is not reported as one that "couldn't be saved".
            guard fileManager.isReadableFile(atPath: path) else {
                return .refused("“\(name)” can’t be read, so it couldn’t be added. Check its permissions in Finder.")
            }
        }

        // 2. The folder: the one already there, whatever its case, or a new one.
        let folder: (path: String, name: String, exists: Bool)
        switch imagesFolder(in: noteFolder, isCloudOnly: isCloudOnly) {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let found): folder = found
        }
        // An image already in the folder is linked where it is: a second copy beside it is clutter
        // in a synced folder.
        let resolvedFolder = URL(fileURLWithPath: folder.path).resolvingSymlinksInPath().path
        func isInPlace(_ source: Source) -> Bool {
            guard folder.exists, case .file(let path) = source else { return false }
            return (path as NSString).deletingLastPathComponent == resolvedFolder
        }
        let incoming = sources.filter { !isInPlace($0) }
        // The size, before anything is written: one drop or paste adds at most 25 MB, since a large
        // copy on the main thread holds the window, for a picture Preview wouldn't draw. Images
        // already in the folder are linked, not copied, and don't count.
        let total = incoming.reduce(0) { $0 + byteCount(of: $1) }
        guard total <= maxTotalBytes else { return .refused(tooLarge(incoming, total: total)) }
        // Asked only of an import that writes: linking images already in a read-only Images
        // folder writes nothing, and must not be refused.
        let writes = !incoming.isEmpty
        guard !writes || isWritable(folder.exists ? folder.path : noteFolder) else {
            return .refused(folder.exists
                ? "The \(folder.name) folder here can’t be written to, so the image couldn’t be added."
                : "This note’s folder can’t be written to, so the image couldn’t be added.")
        }

        // 3. Names, from the note's (`Pasta-1.jpg`), counting on from the highest number in the
        // folder or the note's links. The stem is shortened once, so every name and the count
        // read the same one.
        let stem = fittedStem(imageStem(forNote: notePath))
        let existing = folder.exists ? ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []) : []
        let givenOutKey = givenOut.key(folder: resolvedFolder, stem: stem)
        var number = max(highestNumber(for: stem, among: existing),
                         highestLinkedNumber(for: stem, folder: folder.name, in: noteText),
                         givenOut.highest(for: givenOutKey))

        var madeFolder: String?
        if !folder.exists {
            do {
                try fileManager.createDirectory(atPath: folder.path, withIntermediateDirectories: false)
                madeFolder = folder.path
            } catch {
                return .refused("The \(folder.name) folder couldn’t be made here — \(error.localizedDescription)")
            }
        }

        var written: [String] = []
        var links: [String] = []
        var failure: String?
        for (index, source) in sources.enumerated() {
            if isInPlace(source), case .file(let path) = source {
                links.append(link(folder: folder.name, file: (path as NSString).lastPathComponent))
                continue
            }
            let ext: String
            let label: String
            switch source {
            case .file(let path):
                ext = (path as NSString).pathExtension
                label = "“\((path as NSString).lastPathComponent)”"
            case .data(_, let fileExtension):
                ext = fileExtension
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
                    case .data(let data, _): try EditorFileStore.createNew(data, atPath: path)
                    }
                    landed = name
                } catch is EditorFileStore.AlreadyExists {
                    continue
                } catch {
                    // A failure after the file landed is still a file that landed: the read-back
                    // can fail once the move is done, and an unlinked image on disk is the worst
                    // outcome. Reported as saved but not checked.
                    if (try? fileManager.attributesOfItem(atPath: path)) != nil {
                        landed = name
                        failure = "\(label) was saved in \(folder.name) and linked, but it couldn’t be read "
                            + "back straight afterwards — look at it before relying on it."
                    } else {
                        failure = "\(label) couldn’t be saved in \(folder.name) — \(error.localizedDescription)"
                    }
                }
                break
            }
            if landed == nil {
                failure = failure ?? "\(label) couldn’t be saved in \(folder.name) — every name was taken."
            }
            if let landed {
                givenOut.record(number, for: givenOutKey)
                written.append((folder.path as NSString).appendingPathComponent(landed))
                links.append(link(folder: folder.name, file: landed))
            }
            if let reason = failure {
                // The images after it are not tried: say so, rather than leave them unmentioned.
                let left = sources.count - index - 1
                if left > 0 { failure = reason + (left == 1 ? " The image after it wasn’t added." : " The \(left) images after it weren’t added.") }
                break
            }
        }

        guard !links.isEmpty else {
            // Nothing landed: a folder made for this import goes again, by `rmdir`, which removes
            // only an empty folder, so nothing anybody put there can go with it.
            if let madeFolder, rmdir(madeFolder) != 0 {
                return .wrote(files: [], madeFolder: madeFolder, linked: [],
                              failed: failure ?? "The image couldn’t be saved.")
            }
            return .refused(failure ?? "The image couldn’t be saved.")
        }
        return .wrote(files: written, madeFolder: madeFolder, linked: links, failed: failure)
    }

    /// The most one drop or paste may add: 25 MB as Finder counts it (25,000,000 bytes), so a file
    /// Finder calls 26 MB is refused. Counted over the whole import, before anything is written
    /// (``importImages(_:forNote:linkedIn:isCloudOnly:isWritable:)``). It sits under Preview's own
    /// limit, ``MarkdownImageSource/maxBytes``, so every image added is one Preview draws.
    static let maxTotalBytes = 25_000_000

    /// The bytes `source` would add: a file's size, or the pasted data's.
    private static func byteCount(of source: Source) -> Int {
        switch source {
        case .file(let path):
            return ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
        case .data(let data, _):
            return data.count
        }
    }

    /// A size as Finder and the rest of SyncCloud write it (decimal, `ByteCountFormatter`'s
    /// `.file` style), so the limit reads "25 MB".
    static func sizeText(_ bytes: Int) -> String {
        FileSyncManager.formatBytes(bytes)
    }

    /// Why an import over ``maxTotalBytes`` added nothing: how large it was, and the limit.
    private static func tooLarge(_ incoming: [Source], total: Int) -> String {
        let limit = sizeText(maxTotalBytes)
        // Rounded, a total just over the limit would read as the limit itself.
        let size = sizeText(total) == limit ? "a little over \(limit)" : sizeText(total)
        let what: String
        switch (incoming.count, incoming.first) {
        case (1, .file(let path)?): what = "“\((path as NSString).lastPathComponent)” is \(size)"
        case (1, _): what = "The pasted image is \(size)"
        default: what = "These \(incoming.count) images come to \(size) together"
        }
        return what + ", and one drop or paste can add at most \(limit) of images. Nothing was added."
    }

    /// The folder a note's relative links are read against: the folder its file is in, through a
    /// symlink to the note. Preview, print and the image import all resolve `Images/…` from here.
    ///
    /// A note opened by a symlink is saved where the link leads (``EditorFileStore/resolved(_:)``),
    /// so other apps read its links from there; using the link's own folder would put a pasted image
    /// where the real note can't see it. One `readlink` for a note that isn't a link. A symlinked
    /// folder above the note needs no resolving: `Images/` through it is the same folder.
    public static func linkFolder(ofNote notePath: String) -> String {
        (noteFile(notePath) as NSString).deletingLastPathComponent
    }

    /// The note's own file: `notePath`, or where it leads when it is a symlink.
    static func noteFile(_ notePath: String) -> String {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: notePath)) != nil else { return notePath }
        return EditorFileStore.resolved(notePath)
    }

    // MARK: - The rules, each on its own

    struct Refusal: Error, Equatable { var message: String }

    /// The note folder's Images folder: the one there, in whatever case, or where a new one would
    /// go. Found by listing, not `fileExists`, so a folder made as `images` is linked by its own
    /// name; `Images/x.png` wouldn't open it on GitHub or a case-sensitive volume.
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
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            // Listed, yet not there: an alias whose folder has gone, so the message says alias,
            // not file.
            return .failure(Refusal(message: "“\(name)” in this note’s folder is an alias to a folder that isn’t "
                + "there any more, so the image has nowhere to go. Remove the alias or put its folder back, "
                + "then try again."))
        }
        guard isDirectory.boolValue else {
            return .failure(Refusal(message: "There’s a file called “\(name)” in this note’s folder, so "
                + "the image has nowhere to go. Rename that file, then try again."))
        }
        // Through a symlink to where it leads: `isCloudOnly` reads the link itself, but the folder
        // it points at is the one that would be listed.
        guard !isCloudOnly(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) else {
            return .failure(Refusal(message: "The \(name) folder here is still in the cloud. Open it in "
                + "Finder so it downloads, then try again."))
        }
        return .success((path, name, true))
    }

    /// The note's name without its extension, which the images are named after. A leading dot
    /// would hide every image, so it is dropped; a name that is nothing else becomes "Image".
    /// Composed (NFC) whatever form the file system returns: git stores the composed form, so a
    /// decomposed `Café` in the link wouldn't find `Café-1.png` once pushed.
    static func imageStem(forNote notePath: String) -> String {
        let stem = ((notePath as NSString).lastPathComponent as NSString).deletingPathExtension
            .precomposedStringWithCanonicalMapping
        let visible = String(stem.drop { $0 == "." })
        return visible.isEmpty ? "Image" : visible
    }

    /// Every number given out since the app opened, per Images folder and note name: the third
    /// record, beside the folder and the note's text, which both miss a link held only in undo
    /// history. Without it, a reused number lets ⌘Z bring an old link back over a new picture.
    /// Session-long, like undo; nothing is written down. Keyed case-blind, which can only skip a
    /// number, never repeat one.
    private final class GivenOut: @unchecked Sendable {
        private let lock = NSLock()
        private var numbers: [String: Int] = [:]

        func key(folder: String, stem: String) -> String {
            (folder + "/" + stem).precomposedStringWithCanonicalMapping.lowercased()
        }

        func highest(for key: String) -> Int {
            lock.withLock { numbers[key] ?? 0 }
        }

        func record(_ number: Int, for key: String) {
            lock.withLock { numbers[key] = max(numbers[key] ?? 0, number) }
        }
    }

    private static let givenOut = GivenOut()

    /// The highest `N` among names of the form `<stem>-N.<ext>`, any extension, any case; 0 when
    /// there are none. The highest, not the first gap: a note can still link a deleted
    /// `Pasta-1.jpg`, and a new image by that name would appear in its place. At most six digits,
    /// so a huge typed number isn't counted on from.
    static func highestNumber(for stem: String, among names: [String]) -> Int {
        let prefix = (stem + "-").lowercased()
        return names.reduce(0) { highest, name in
            let base = ((name as NSString).deletingPathExtension).lowercased()
            guard base.hasPrefix(prefix), !(name as NSString).pathExtension.isEmpty else { return highest }
            return max(highest, number(base.dropFirst(prefix.count)) ?? 0)
        }
    }

    /// The highest `N` the note's text links as `<folder>/<stem>-N.…`, percent-encoded as Edit
    /// writes it or plain inside `<…>`, composed or decomposed, since the match is by bytes.
    static func highestLinkedNumber(for stem: String, folder: String, in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var highest = 0
        let forms = [stem.precomposedStringWithCanonicalMapping, stem.decomposedStringWithCanonicalMapping]
        for spelling in Set(forms.flatMap { [link(folder: folder, file: $0), folder + "/" + $0] }) {
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

    /// The stem shortened so `<stem>-NNNNNN.<extension>` fits the 255-byte name limit for any
    /// extension up to 16 bytes. Done once, so the names and the count agree on it.
    static func fittedStem(_ stem: String) -> String {
        var fitted = stem
        while fitted.utf8.count > 255 - 24, !fitted.isEmpty { fitted.removeLast() }
        return fitted.isEmpty ? "Image" : fitted
    }

    /// The link as it goes in the note: `Images/<name>`, each part percent-encoded down to letters,
    /// digits and `-._~`, so it is portable CommonMark that ``MarkdownImageSource`` decodes back.
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
