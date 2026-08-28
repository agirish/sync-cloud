import Foundation

/// An inbox subtree shadowing a real destination (ROADMAP_V5 §5.2).
///
/// `Health/TODO/Dental` beside `Health/Dental` is a filing decision deferred twice: the document
/// went into the inbox, then got a folder there, so the same category now exists in both worlds
/// and every later filing has to choose. The rule: a folder strictly **inside** an inbox whose
/// path with the inbox component removed names a folder that exists.
///
/// The inbox component must be a strict ancestor — the inbox folder itself always "mirrors" its
/// parent by this construction and is not a finding. And the reference tree cannot validate this
/// detector: the 6 Aug TODO drain cleared the class it detects, which is why its count there is
/// pinned at zero and its firing case is synthetic. (The one candidate that tree still holds,
/// `Finance/US/TODO/IRS/IRS`, is a child restating its parent's name *inside* an inbox — that is
/// parent/child echo's observation, and the echo detector names it precisely; a mirror rule bent
/// to also catch it would fire on a path whose de-inboxed form exists nowhere.)
enum StructureMirroredInbox {

    static func findings(in profile: FolderProfile) -> [StructureFinding] {
        var out: [StructureFinding] = []
        for path in profile.folders.keys {
            let components = path.split(separator: "/").map(String.init)
            guard components.count >= 2 else { continue }
            // The deepest qualifying inbox ancestor wins; one finding per folder.
            for index in (0..<(components.count - 1)).reversed()
            where FolderProfile.isInboxPath(components[index]) {
                var mirrored = components
                mirrored.remove(at: index)
                let destination = mirrored.joined(separator: "/")
                if profile.folders[destination] != nil {
                    out.append(StructureFinding(
                        kind: .mirroredInbox,
                        family: (path as NSString).deletingLastPathComponent,
                        subject: path,
                        detail: .mirroredInbox(destination: destination)))
                }
                break
            }
        }
        return out.sorted { $0.subject < $1.subject }
    }
}
