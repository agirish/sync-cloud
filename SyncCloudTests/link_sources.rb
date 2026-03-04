require 'xcodeproj'

project_path = '../SyncCloud.xcodeproj'
project = Xcodeproj::Project.open(project_path)

test_target = project.targets.find { |t| t.name == 'SyncCloudTests' }
main_target = project.targets.find { |t| t.name == 'SyncCloud' }

if test_target.nil?
  puts "Target still nil"
  exit 1
end

# Establish test dependency
test_target.add_dependency(main_target)

# Add XCTest Framework 
frameworks = project.frameworks_group
# xctest_ref = frameworks.new_file('Developer/Library/Frameworks/XCTest.framework', :developer_dir)
# test_target.frameworks_build_phase.add_file_reference(xctest_ref)

test_group = project.main_group.find_subpath(File.join('SyncCloudTests'), true)
test_group.set_source_tree('<group>')
test_group.set_path('SyncCloudTests')

# Grab the source files from disk
Dir.glob("../*.swift").each do |file|
   puts file
end

mock_file = test_group.new_file('MockFileManager.swift')
test_case1 = test_group.new_file('FileDiffEngineTests.swift')

test_target.source_build_phase.add_file_reference(mock_file)
test_target.source_build_phase.add_file_reference(test_case1)

# Generate Scheme
scheme = Xcodeproj::XCScheme.new
scheme.add_test_target(test_target)
scheme.save_as(project_path, 'SyncCloudTests', true)

project.save
puts "Linked sources and saved schema"
