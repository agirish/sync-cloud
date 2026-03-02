require 'xcodeproj'
project_path = '/Users/abhishek/Projects/vibe-code/SyncCloud/SyncCloud.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first
group = project.main_group.find_subpath('MacApp', true)

['MacApp/Logger.swift', 'MacApp/LogViewer.swift'].each do |file|
  file_ref = group.new_reference(File.basename(file))
  target.add_file_references([file_ref])
end

project.save
