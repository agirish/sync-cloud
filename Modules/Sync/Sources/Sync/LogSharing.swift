import Foundation

/// "Copy Log for Sharing": the log with what identifies the owner masked, for a bug report.
///
/// The file on disk keeps everything: paths, emails and names are what make it useful for
/// troubleshooting, and it never leaves the Mac on its own. The copy masks, in this order:
///
/// 1. **Emails**, keeping a provider's prefix: `GoogleDrive-a.b@x.com` becomes
///    `GoogleDrive-<account>`. First, because a person's name can sit inside an address.
/// 2. **The home folder's paths**: `/Users/<you>` and the `-Users-<you>-` spelling some tools use
///    for paths.
/// 3. **People's names**: every name form of everyone in every filing profile's People list
///    (display names, full names, aliases, and the ids, which are built from names), whole and
///    word by word, as `<person N>`, numbered in roster order and the same number throughout one
///    copy. Then everyone the log's own People lines name (added, updated, removed), numbered on
///    from there: people removed from a list since, and names a person had before a rename.
/// 4. **The bare account name**, last: an account named for its owner is often a People name too,
///    and masked first it would split "Anna Smith" into "<you> Smith" before the full form matched.
///
/// Names match on letter boundaries (`_`, digits and punctuation count as boundaries), ignoring
/// case for forms of 4 letters or more and for forms stored in lower case (a suggested list's,
/// whose spelling in the tree isn't known), after NFC on both sides; the fallback id `person` is never
/// matched. What can't be masked this way is said in the copy's header, so the reader knows.
public enum LogSharing {

    /// Everyone in every profile under `profilesDirectory`, in profile then roster order, each
    /// person once by id with every name form any profile gives them. A profile's roster is its
    /// `people.json`, or, when that is absent or doesn't read, the list People suggests from its
    /// folder survey (``PersonRegistry/seeded(from:)``), which Settings shows though it is never
    /// written.
    public static func roster(profilesDirectory: URL?, fileManager: FileManager = .default) -> [Person] {
        guard let profilesDirectory,
              let profiles = try? fileManager.contentsOfDirectory(atPath: profilesDirectory.path) else { return [] }
        struct File: Decodable { let people: [Person] }
        var everyone: [Person] = []
        for profile in profiles.sorted() {
            let folder = profilesDirectory.appendingPathComponent(profile)
            let people: [Person]
            if let data = try? Data(contentsOf: folder.appendingPathComponent("people.json")),
               let file = try? JSONDecoder().decode(File.self, from: data) {
                people = file.people
            } else if let data = try? Data(contentsOf: FilingProfileStore.profileURL(id: profile, in: profilesDirectory)),
                      let folderProfile = try? JSONDecoder().decode(FolderProfile.self, from: data) {
                people = PersonRegistry.seeded(from: folderProfile).people
            } else {
                continue
            }
            everyone += people
        }
        return merged(everyone)
    }

    /// `people`, each id once, in order of first appearance, with every name form any of its
    /// entries gives: the same id in another profile, or on another log line, can carry other
    /// forms ("Anna Smith", "Mom"), and all go.
    static func merged(_ people: [Person]) -> [Person] {
        var order: [String] = []
        var byID: [String: Person] = [:]
        for person in people {
            guard var known = byID[person.id] else {
                order.append(person.id)
                byID[person.id] = person
                continue
            }
            for form in person.nameForms where !known.nameForms.contains(form) {
                if person.fullNames.contains(form) { known.fullNames.append(form) } else { known.aliases.append(form) }
            }
            byID[person.id] = known
        }
        return order.compactMap { byID[$0] }
    }

    /// `People: added 'Anna' (anna-smith)` and `updated` alike, as `PeopleStore` writes them, and
    /// `removed`, which adds the person's other names: `(anna-smith; Anna Smith, Mom)`. A removed
    /// line written before 7.2 has neither.
    private static let peopleLine = try! NSRegularExpression(
        pattern: #"People: (?:added|updated|removed) '(.+?)'(?: \(([^()\n]+)\))?(?= —| \(|$)"#,
        options: [.anchorsMatchLines])

    /// Everyone `log`'s People lines name, by id, in order of first appearance. A line with no id
    /// joins the person already named by that display name, or stands alone keyed by it.
    static func peopleNamed(inLog log: String) -> [Person] {
        var people: [Person] = []
        for match in peopleLine.matches(in: log, range: NSRange(log.startIndex..., in: log)) {
            guard let nameRange = Range(match.range(at: 1), in: log) else { continue }
            let name = String(log[nameRange])
            let detail = Range(match.range(at: 2), in: log).map { log[$0].components(separatedBy: "; ") } ?? []
            let id = detail.first ?? people.first { $0.nameForms.contains(name) }?.id ?? name
            let others = detail.dropFirst().joined(separator: "; ").components(separatedBy: ", ").filter { !$0.isEmpty }
            people.append(Person(id: id, displayName: name, aliases: others))
        }
        return people
    }

    /// The header the copy opens with: what was masked, and what wasn't.
    public static let header = """
        SyncCloud log, copied for sharing. Masked: email addresses, your home folder and account \
        name, and the names in your People lists (as <person N>). Not masked: file and folder \
        names, names written together with other letters, this Mac’s name, an organization in a \
        OneDrive folder name, and people removed from a People list before this log begins.
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

    /// `text` with emails, the home folder and People names masked (see the type's comment):
    /// `people`, then everyone `text`'s own People lines name.
    public static func mask(_ text: String, home: String, people: [Person]) -> String {
        var out = text.precomposedStringWithCanonicalMapping
        let everyone = merged(people + peopleNamed(inLog: out))
        out = maskEmails(out)
        out = maskHomePaths(out, home: home)
        out = maskPeople(out, people: everyone)
        out = maskAccount(out, home: home)
        return out
    }

    // MARK: - Steps

    private static let email = try! NSRegularExpression(
        pattern: #"((?:GoogleDrive|OneDrive|Box)-)?[\p{L}\p{M}\p{N}._%+-]+@[\p{L}\p{M}\p{N}.-]+\.[\p{L}\p{M}]{2,}"#)

    static func maskEmails(_ text: String) -> String {
        email.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1<account>")
    }

    /// The account name `home` ends in; nil for a home that names none.
    private static func homeAndAccount(_ home: String) -> (home: String, account: String)? {
        let home = (home as NSString).standardizingPath
        let account = (home as NSString).lastPathComponent
        guard !account.isEmpty, account != "/" else { return nil }
        return (home, account)
    }

    static func maskHomePaths(_ text: String, home: String) -> String {
        guard let found = homeAndAccount(home) else { return text }
        // Only the folder itself: `/Users/jdoe` must not turn `/Users/jdoely` into `~ly`.
        let path = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: found.home) + #"(?![\p{L}\p{N}._-])"#)
        let out = path.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
        return out.replacingOccurrences(of: "-Users-\(found.account)-", with: "-Users-<you>-")
    }

    static func maskAccount(_ text: String, home: String) -> String {
        guard let account = homeAndAccount(home)?.account else { return text }
        return replaceWord(account, with: "<you>", in: text, ignoringCase: account.count >= 4)
    }

    static func maskPeople(_ text: String, people: [Person]) -> String {
        // Longer forms first, so "Anna Smith" is masked whole before "Anna".
        var forms: [(form: String, number: Int)] = []
        for (index, person) in people.enumerated() {
            // Each form whole, then each word of it: a surname must not survive "Anna_Smith.pdf",
            // "Smith, Anna" or two spaces between them.
            let whole = (person.nameForms + [person.id]).map {
                $0.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
            }
            let words = whole.flatMap { $0.split(whereSeparator: { !$0.isLetter }).map(String.init) }
            for form in Set(whole + words) {
                guard form.count >= 2, form.lowercased() != "person" else { continue }
                forms.append((form, index + 1))
            }
        }
        forms.sort { $0.form.count > $1.form.count }
        var out = text
        for (form, number) in forms {
            out = replaceWord(form, with: "<person \(number)>", in: out,
                              ignoringCase: form.count >= 4 || form == form.lowercased())
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
