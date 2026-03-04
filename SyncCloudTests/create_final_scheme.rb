require 'xcodeproj'

project_path = '../SyncCloud.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'SyncCloudTests' }
if target
    scheme = Xcodeproj::XCScheme.new
    scheme.add_test_target(target)
    scheme.save_as(project_path, 'SyncCloudTests', true)
    puts "Forced scheme generation."
else
    puts "Target not found."
end
