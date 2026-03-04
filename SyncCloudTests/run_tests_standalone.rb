require 'xcodeproj'

project_path = '../SyncCloud.xcodeproj'
project = Xcodeproj::Project.open(project_path)
project.recreate_user_schemes
project.save
puts "Recreated all user schemes"
