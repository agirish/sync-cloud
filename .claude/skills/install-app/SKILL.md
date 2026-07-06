---
name: install-app
description: Copy the latest built SyncCloud.app to /Applications. Use when the user asks to install, deploy, or copy the app to Applications.
---

Install the most recent SyncCloud build into /Applications:

1. Find the newest built app bundle:
   ```bash
   APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/SyncCloud-*/Build/Products/*/SyncCloud.app | head -1)
   ```
2. Compare the binary's mtime (`stat -f '%Sm' "$APP/Contents/MacOS/SyncCloud"`) with the latest commit (`git log -1 --format='%ci %h %s'`). If the build is older than HEAD, rebuild first (`xcodebuild -project SyncCloud.xcodeproj -scheme SyncCloud build`) and re-resolve `$APP`.
3. If the app is running (`pgrep -fl 'SyncCloud.app/Contents/MacOS/SyncCloud'`), quit it and tell the user.
4. Replace the installed copy:
   ```bash
   rm -rf /Applications/SyncCloud.app && ditto "$APP" /Applications/SyncCloud.app
   ```
5. Confirm by reporting the installed binary's timestamp.
