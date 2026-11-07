import Foundation

/// "Copy Log for Sharing": the log with what identifies the owner masked, for a bug report.
///
/// The file on disk keeps everything: paths, emails and names are what make it useful for
/// troubleshooting, and it never leaves the Mac on its own. The copy masks, in this order:
///
/// 1. **Emails**, keeping a provider's prefix: `GoogleDrive-a.b@x.com` becomes
///    `GoogleDrive-<account>`. First, because a person's name can sit inside an address.
/// 2. **The home folder** in each form it takes: `/Users/<you>`, the `-Users-<you>-` spelling some
///    tools use for paths, and the bare account name.
/// 3. **People's names**: every name form of everyone in every filing profile's People list
///    (display names, full names, aliases, and the ids, which are built from names), as
///    `<person N>`, numbered in roster order and the same number throughout one copy.
///
/// Names match on letter boundaries (`_`, digits and punctuation count as boundaries), ignoring
/// case for forms of 4 letters or more, after NFC on both sides; the fallback id `person` is never
/// matched. What can't be masked this way is said in the copy's header, so the reader knows.
public enum LogSharing {

    /// Everyone in every profile's `people.json` under `profilesDirectory`, in profile then
    /// roster order, each person once by id. A profile whose roster doesn't read is skipped.
    public static func roster(profilesDirectory: URL?, fileManager: FileManager = .default) -> [Person] {
        guard let profilesDirectory,
              let profiles = try? fileManager.contentsOfDirectory(atPath: profilesDirectory.path) else { return [] }
        struct File: Decodable { let people: [Person] }
        var seen: Set<String> = []
        var out: [Person] = []
        for profile in profiles.sorted() {
            let url = profilesDirectory.appendingPathComponent(profile).appendingPathComponent("people.json")
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(File.self, from: data) else { continue }
            for person in file.people where seen.insert(person.id).inserted { out.append(person) }
        }
        return out
    }

    /// The header the copy opens with: what was masked, and what wasn't.
    public static let header = """
        SyncCloud log, copied for sharing. Masked: email addresses, your home folder and account \
        name, and the names in your People lists (as <person N>). Not masked: file and folder \
        names, names written together with other letters, this Mac’s name, an organization in a \
        OneDrive folder name, and people no longer in a People list.
        """

    /// The whole log file at `fileURL`, masked, under ``header``: what "Copy Log for Sharing" puts
    /// on the clipboard. Waits for `drainWriter` first, so the copy holds every line written so
    /// far; reads the disk, so call it off the main actor. Nil when the file doesn't read.
    /// `home` and `profilesDirectory` come from the caller, never defaulted here: library code
    /// doesn't reach into the real home directory (``FilingProfileStore/defaultDirectory(fileManager:)``).
    public static func sharedCopy(of fileURL: URL, drainWriter: () -> Void,
                                  home: String, profilesDirectory: URL?) -> String? {
        drainWriter()
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return header + "\n\n" + mask(text, home: home, people: roster(profilesDirectory: profilesDirectory))
    }

    /// `text` with emails, the home folder and People names masked (see the type's comment).
    public static func mask(_ text: String, home: String, people: [Person]) -> String {
        var out = text.precomposedStringWithCanonicalMapping
        out = maskEmails(out)
        out = maskHome(out, home: home)
        out = maskPeople(out, people: people)
        return out
    }

    // MARK: - Steps

    private static let email = try! NSRegularExpression(
        pattern: #"((?:GoogleDrive|OneDrive|Box)-)?[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

    static func maskEmails(_ text: String) -> String {
        email.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1<account>")
    }

    static func maskHome(_ text: String, home: String) -> String {
        let home = (home as NSString).standardizingPath
        let account = (home as NSString).lastPathComponent
        guard !account.isEmpty, account != "/" else { return text }
        // Only the folder itself: `/Users/jdoe` must not turn `/Users/jdoely` into `~ly`.
        let path = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: home) + #"(?![\p{L}\p{N}._-])"#)
        var out = path.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
        out = out.replacingOccurrences(of: "-Users-\(account)-", with: "-Users-<you>-")
        return replaceWord(account, with: "<you>", in: out, ignoringCase: account.count >= 4)
    }

    static func maskPeople(_ text: String, people: [Person]) -> String {
        // Longer forms first, so "Anna Smith" is masked whole before "Anna".
        var forms: [(form: String, number: Int)] = []
        for (index, person) in people.enumerated() {
            for form in Set(person.nameForms + [person.id]) {
                let form = form.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
                guard form.count >= 2, form.lowercased() != "person" else { continue }
                forms.append((form, index + 1))
            }
        }
        forms.sort { $0.form.count > $1.form.count }
        var out = text
        for (form, number) in forms {
            out = replaceWord(form, with: "<person \(number)>", in: out, ignoringCase: form.count >= 4)
        }
        return out
    }

    /// `word` replaced wherever it stands between letter boundaries: not inside another word,
    /// but `_`, digits and punctuation around it count as edges.
    static func replaceWord(_ word: String, with replacement: String, in text: String, ignoringCase: Bool) -> String {
        let pattern = #"(?<!\p{L})"# + NSRegularExpression.escapedPattern(for: word) + #"(?!\p{L})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: ignoringCase ? [.caseInsensitive] : []) else {
            return text
        }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
