import Foundation

// A simple script to add files to a pbxproj file
let projectPath = "/Users/abhishek/Projects/vibe-code/SyncCloud/SyncCloud.xcodeproj/project.pbxproj"
do {
    var pbxProj = try String(contentsOfFile: projectPath, encoding: .utf8)
    
    // We need to generate unique 24-character hex IDs for the new files
    func newID() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).uppercased()
    }
    
    let loggerFileID = newID()
    let loggerBuildID = newID()
    let logViewerFileID = newID()
    let logViewerBuildID = newID()
    
    // 1. Add to PBXBuildFile section
    if let buildFileRange = pbxProj.range(of: "/* End PBXBuildFile section */") {
        let newBuildFiles = """
        \t\t\(loggerBuildID) /* Logger.swift in Sources */ = {isa = PBXBuildFile; fileRef = \(loggerFileID) /* Logger.swift */; };
        \t\t\(logViewerBuildID) /* LogViewer.swift in Sources */ = {isa = PBXBuildFile; fileRef = \(logViewerFileID) /* LogViewer.swift */; };\n
        """
        pbxProj.insert(contentsOf: newBuildFiles, at: buildFileRange.lowerBound)
    }
    
    // 2. Add to PBXFileReference section
    if let fileRefRange = pbxProj.range(of: "/* End PBXFileReference section */") {
        let newFileRefs = """
        \t\t\(loggerFileID) /* Logger.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Logger.swift; sourceTree = "<group>"; };
        \t\t\(logViewerFileID) /* LogViewer.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LogViewer.swift; sourceTree = "<group>"; };\n
        """
        pbxProj.insert(contentsOf: newFileRefs, at: fileRefRange.lowerBound)
    }
    
    // 3. Add to the MacApp group's children array
    // We need the ID of the MacApp group. Let's find "path = MacApp; sourceTree = \"<group>\";" and find its children array.
    if let macAppGroupRange = pbxProj.range(of: "/* MacApp */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (") {
        let newChildren = """
        \n\t\t\t\t\(loggerFileID) /* Logger.swift */,
        \t\t\t\t\(logViewerFileID) /* LogViewer.swift */,
        """
        pbxProj.insert(contentsOf: newChildren, at: macAppGroupRange.upperBound)
    }
    
    // 4. Add to the main app target's PBXSourcesBuildPhase
    // Look for "isa = PBXSourcesBuildPhase;" and its files array. We want the one for the main app target.
    // It usually has "runOnlyForDeploymentPostprocessing = 0;" nearby.
    // Let's find the specific Sources build phase by looking for the one that already has ContentView.swift
    if let sourcesPhaseRange = pbxProj.range(of: "isa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask") {
        // we'll find the specific `files = (` that follows this
        if let filesRange = pbxProj[sourcesPhaseRange.upperBound...].range(of: "files = (") {
             let newSources = """
             \n\t\t\t\t\(loggerBuildID) /* Logger.swift in Sources */,
             \t\t\t\t\(logViewerBuildID) /* LogViewer.swift in Sources */,
             """
             pbxProj.insert(contentsOf: newSources, at: filesRange.upperBound)
        }
    }
    
    try pbxProj.write(toFile: projectPath, atomically: true, encoding: .utf8)
    print("Successfully modified project.pbxproj")
} catch {
    print("Error modifying pbxproj: \\(error)")
}
