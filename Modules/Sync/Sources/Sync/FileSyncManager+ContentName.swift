import Foundation

extension FileSyncManager {

    /// The name a `.ext` file whose first page gave `facts` takes in `folder` (TE328), in the style
    /// of that folder by the survey that answers for it, or nil when the facts are too thin. The
    /// folder's files shape it, its hidden ones left out; a folder not made yet has none.
    public func contentName(_ facts: ContentName.Facts, ext: String, into folder: String,
                            isHidden: (String) -> Bool) -> ContentName.Proposal? {
        let survey = filingHelpSurvey(for: folder)
        let relative = survey.flatMap { Self.surveyRelativePath(folder, root: $0.root) } ?? ""
        return ContentName.propose(facts, ext: ext, folderPath: folder, relativePath: relative,
                                   folderFiles: Self.namingFiles(in: folder, isHidden: isHidden), profile: survey?.profile)
    }

    /// `folder` relative to a survey's `root` ("" for the root itself), through links, or nil
    /// outside it.
    nonisolated static func surveyRelativePath(_ folder: String, root: String) -> String? {
        let f = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
        let r = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        if f == r { return "" }
        return f.hasPrefix(r + "/") ? String(f.dropFirst(r.count + 1)) : nil
    }

    /// The files directly in `folder` whose names may shape a new one: not hidden, not folders.
    nonisolated static func namingFiles(in folder: String, isHidden: (String) -> Bool,
                                        fileManager fm: FileManager = .default) -> [FolderFile] {
        let url = URL(fileURLWithPath: folder)
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true { return nil }
            // Spelled from the folder as given, so a link's spelling is kept.
            let path = (folder as NSString).appendingPathComponent(item.lastPathComponent)
            return isHidden(path) ? nil : FolderFile(path: path, name: item.lastPathComponent)
        }
    }
}
