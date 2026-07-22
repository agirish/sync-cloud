# CI

`.github/workflows/tests.yml` runs the seven SPM package test suites on every
push to `main`, on a self-hosted runner (GitHub-hosted macOS minutes bill at
10x on a private repo, and the hosted toolchain lags the one this repo is
developed against).

## Scope

- All seven packages: `Modules/{Sync, Events, Settings, Design, Dashboard,
  FileExplorer}` and `SyncCloudCLI`.
- Machine-pinned image snapshots (`*SnapshotTests` suites, see
  `Modules/Design/SNAPSHOTS.md`) are excluded with `--skip SnapshotTests`:
  their reference PNGs only match the machine that recorded them. They still
  compile, so breakage in snapshot test code is caught.
- App-target tests (`SyncCloudTests/`, needs `xcodegen` + `xcodebuild test`)
  are not run; possible phase 2.
- The loop runs every package even after a failure so one run reports all
  broken packages.

## Runner

Registered as `synccloud-mac` (labels `self-hosted`, `macOS`), installed at
`~/actions-runner-synccloud`. Re-register after a machine move:

```sh
cd ~/actions-runner-synccloud
./config.sh --url https://github.com/agirish/sync-cloud --token <from repo settings → Actions → Runners → New> --name synccloud-mac --unattended
```

### Known issue: fork deadlock on macOS 26 (Tahoe)

macOS 26 has a fork regression: children forked from a multithreaded process
can wedge pre-exec, spinning one thread at 100% CPU (observed with the
runner's .NET host; also reported against Ruby on 26.1). Symptom: a job step
"runs" forever, `ps` shows a second `Runner.Worker spawnclient` process in
state `R` at 100% CPU with a tiny footprint, and killing it only makes the
worker fork another. Ruled out by direct A/B on this machine:
`DOTNET_EnableWriteXorExecute=0` (verified present in the worker's env, still
wedged), LaunchAgent vs interactive `./run.sh` (both wedge). The arm64 agent
wedged in 3 of 3 runs, at a different spawn each time.

Current mitigation: the agent runs as the **osx-x64 build under Rosetta**
(`~/actions-runner-synccloud-x64`, same registration — the `.runner` /
`.credentials*` files are arch-independent and were copied over), which takes
a different fork path through the translation layer. If a run wedges anyway:
kill the `Runner.Worker` processes, restart the runner, re-run the workflow.
Track the OS bug before blaming test code — every wedge so far happened in
the runner agent, never in `swift test`.

### Rosetta corollary: `swift test` exit code lies under x86_64

Under the x64 agent, `swift test` inherits x86_64 and then **exits 1 with
every test passing** (isolated by A/B: same workspace + native arm64 → 0;
x86_64 → 1; env and cwd innocent). The workflow therefore runs the payload
as `arch -arm64 swift test …`. When checking test outcomes by hand, never
judge from piped output (`… | tail`) — the pipe masks the real exit code;
that mistake let this slip past local verification once already.
