---
name: install-app
description: Copy the latest built SyncCloud.app to /Applications. Use when the user asks to install, deploy, or copy the app to Applications.
---

Install the most recent SyncCloud build into /Applications.

Every check below is here because it failed once and reported success anyway — keep the reasons attached.

**macOS has no `timeout(1)`.** `timeout 5 some-cmd` exits **127 (command not found)** for *every* input, which reads exactly like "everything timed out" — on 2026-07-30 that made a purely local path and every cloud root look equally blocked and sent the investigation the wrong way. Wherever a command must be bounded, background it and poll `kill -0 $!` instead (steps 3 and 7).

1. Find the newest built app bundle. Two roots matter: the shared DerivedData path, and the **current worktree's `.dd`** — CLAUDE.md has each session build in its own worktree with `xcodebuild -derivedDataPath .dd`, so the freshest bundle is often there and a DerivedData-only search silently installs someone else's older build. Pick by **binary** mtime, not bundle mtime: `ditto`/`lsregister` touch the bundle, so the directory timestamp can be newer than the code inside it.
   ```bash
   APP=$( { find "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.dd/Build/Products" \
                 -maxdepth 2 -name 'SyncCloud.app' -type d 2>/dev/null
            find ~/Library/Developer/Xcode/DerivedData \
                 -maxdepth 5 -path '*/SyncCloud-*/Build/Products/*/SyncCloud.app' -type d 2>/dev/null
          } | while read -r a; do
            printf '%s\t%s\n' "$(stat -f %m "$a/Contents/MacOS/SyncCloud" 2>/dev/null || echo 0)" "$a"
          done | sort -rn | head -1 | cut -f2- )
   echo "$APP"
   ```
   Use `find`, not a glob: under zsh a non-matching `*/SyncCloud.app` glob aborts the **whole command**, so a session with no `.dd` yet would fail to resolve `$APP` at all rather than falling through to DerivedData.
2. Compare the binary's mtime (`stat -f '%Sm' "$APP/Contents/MacOS/SyncCloud"`) with the latest commit (`git log -1 --format='%ci %h %s'`). If the build is older than HEAD, rebuild first (`xcodebuild -project SyncCloud.xcodeproj -scheme SyncCloud build`) and re-resolve `$APP`.
3. If the app is running (`pgrep -fl 'SyncCloud.app/Contents/MacOS/SyncCloud'`), quit it and tell the user — and **verify the quit landed**. A modal sheet or an unsaved-changes prompt makes the app refuse the AppleEvent, which fails with `User canceled. (-128)`; `rm -rf` then succeeds anyway (the running process holds the inode) and `open` merely re-activates the *old* instance, so the whole install reports success while the user stays on the previous build. The AppleEvent can also **hang** instead of failing — a wedged app never answers and `osascript` sits until it returns `AppleEvent timed out. (-1712)`, which took ~2 minutes on 2026-07-30 and blocked the `pkill` fallback behind it. So bound the wait rather than letting `osascript` set the pace:
   ```bash
   osascript -e 'quit app "SyncCloud"' & OSA=$!
   for _ in $(seq 1 15); do kill -0 $OSA 2>/dev/null || break; sleep 1; done
   kill -0 $OSA 2>/dev/null && kill -9 $OSA 2>/dev/null   # AppleEvent hung; stop waiting on it
   sleep 2
   if pgrep -f 'SyncCloud.app/Contents/MacOS/SyncCloud' >/dev/null; then
     pkill -TERM -f 'SyncCloud.app/Contents/MacOS/SyncCloud'; sleep 3
   fi
   pgrep -fl 'SyncCloud.app/Contents/MacOS/SyncCloud' || echo "quit OK"
   ```
4. Replace the installed copy:
   ```bash
   rm -rf /Applications/SyncCloud.app && ditto "$APP" /Applications/SyncCloud.app
   ```
5. Unregister the DerivedData copy from LaunchServices AND delete it, so macOS search (Spotlight indexes the bundle on disk) shows only the installed app. The next build recreates it:
   ```bash
   /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -u "$APP" && rm -rf "$APP"
   ```
6. If Spotlight still shows extra SyncCloud entries, other sessions' worktree builds left bundles behind — find them with `mdfind "kMDItemFSName == 'SyncCloud.app'"` and delete any DerivedData copies not part of an active build (`pgrep -fl xcodebuild` first).
7. Launch the freshly installed app and **verify it actually got through launch**. Neither a silent `open` exit nor a `pgrep` hit is proof: on 2026-07-30 the app launched with a live process, **zero windows, and not one line written to `~/sync-cloud.log`** — the main thread was blocked in `getxattr` inside a SwiftUI `body` getter. `open` exited 0, `pgrep` printed the pid, step 9's timestamp check passed, and the install reported "the app is running" over a dead app. `pgrep` proves a process exists; it says nothing about whether that process ever finished launching.

   The one signal that distinguishes the two is the app's own log. A healthy launch writes `SyncCloud <version> (build N) launched`, then `Loading Left Tree for path: …` / `Left Tree Loaded. Count: …`, then a scan — all within ~5s (measured 21:51:20 → `Scan completed` 21:51:28). The wedged launch wrote nothing, ever. So record the log size *before* `open` and poll for new bytes after, with a generous window:
   ```bash
   LOG=~/sync-cloud.log
   BEFORE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
   open /Applications/SyncCloud.app
   for _ in $(seq 1 30); do
     AFTER=$(wc -c < "$LOG" 2>/dev/null || echo 0)
     [ "$AFTER" -ne "$BEFORE" ] && break
     sleep 1
   done
   if [ "$AFTER" -ne "$BEFORE" ]; then
     echo "LAUNCH OK — new log output:"; tail -c "+$((BEFORE+1))" "$LOG" | head -20
   else
     echo "LAUNCH FAILED — no log output in 30s; the app did not start. Go to step 8."
   fi
   ```
   Compare with `-ne`, not `-gt`: if the log was rotated or truncated the new file is *smaller*, and `-gt` would read that as "no output" and fail a healthy launch.

   **Do not substitute a window count for this check.** `osascript -e 'tell application "System Events" to get count of windows of process "SyncCloud"'` fails on this machine with `-25211 osascript is not allowed assistive access`, so it returns an error (or 0) whether the app is healthy or wedged — it cannot tell the two apart and will condemn a good build.
8. If step 7 reported LAUNCH FAILED, **diagnose it — do not report success, and do not guess.** The process is alive but stuck, so the question is *where*. `sample` answers that in seconds and was the only thing that told the truth on 2026-07-30; Console and the log are empty by definition in this failure, because the app never got far enough to write anything.
   ```bash
   PID=$(pgrep -f 'SyncCloud.app/Contents/MacOS/SyncCloud' | head -1)
   sample "$PID" 3 -file /tmp/synccloud-sample.txt >/dev/null
   sed -n '/com.apple.main-thread/,/^$/p' /tmp/synccloud-sample.txt | head -40
   ```
   Report the top main-thread frames verbatim — that stack names the blocking call (e.g. `getxattr` under a SwiftUI `body` getter). If `pgrep` finds no pid at all, the app crashed rather than hung; look for a report under `~/Library/Logs/DiagnosticReports/SyncCloud-*.ips`.
9. Confirm the running process is the one just installed, not a survivor of step 3: its start time must be **later** than the installed binary's mtime.
   ```bash
   ps -p $(pgrep -f 'SyncCloud.app/Contents/MacOS/SyncCloud' | head -1) -o lstart=
   stat -f '%Sm' /Applications/SyncCloud.app/Contents/MacOS/SyncCloud
   ```
   This check passes on a wedged app too — a process that hangs during launch still started after the binary was written — so it confirms *which build* is running, never *that the app works*. Step 7 is what establishes the latter.
10. Report both timestamps **and the new log lines from step 7** as the evidence the app is running. If step 8 ran, report the blocking frame instead and say plainly that the install did not come up.
