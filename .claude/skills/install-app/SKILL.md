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
5. Unregister the DerivedData copy from LaunchServices AND delete it, so macOS search (Spotlight indexes the bundle on disk) shows only the installed app. The next build recreates it:
   ```bash
   /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -u "$APP" && rm -rf "$APP"
   ```
6. If Spotlight still shows extra SyncCloud entries, other sessions' worktree builds left bundles behind — find them with `mdfind "kMDItemFSName == 'SyncCloud.app'"` and delete any DerivedData copies not part of an active build (`pgrep -fl xcodebuild` first).
7. Launch the freshly installed app and **verify it actually started** — a silent `open` exit is not proof:
   ```bash
   open /Applications/SyncCloud.app && sleep 2 && pgrep -fl 'SyncCloud.app/Contents/MacOS/SyncCloud'
   ```
   If `pgrep` prints nothing, the app failed to launch — investigate (check Console/`~/sync-cloud.log`) rather than reporting success.
8. Confirm by reporting the installed binary's timestamp and that the app is running.
