# AGENTS.md

## What this is

PowerShell 7 tool that injects a rotating image/video overlay into the **ZCode** editor (Chromium/Electron) via Chrome DevTools Protocol. PowerShell 5.1 is NOT supported (encoding breaks); always `pwsh`.

- **Windows**: the original target. Needs a live Windows box with ZCode + pwsh to verify.
- **Linux (Ubuntu 26.04)**: fully supported since the cross-platform port. The dev checkout on this machine IS Ubuntu 26.04 with `/opt/ZCode/zcode` (deb, v3.x) installed, so the core can be smoke-tested and even run end-to-end right here. Windows-only install paths still require Windows.

## Layout

- `zcode-background.ps1` — core runtime, cross-platform. Starts a local HTTP media server (port 9231, auto-increments), restarts ZCode with `--remote-debugging-port=9230`, injects an overlay JS script over CDP WebSocket, then **blocks until ZCode exits** (media server shuts down on exit).
- `install-zcode-background-shortcut.ps1` — **Windows-only** installer. Validates resources → auto-detects ZCode install → rebuilds `zcode-background-launcher.exe` from `zcode-background-launcher.cs` if source is newer → writes a desktop `.lnk` whose target arguments are fully resolved absolute paths.
- `install-zcode-background-linux.ps1` — **Linux** installer. Validates resources → auto-detects ZCode (process → PATH → `/opt/ZCode/zcode` etc.) → ensures pwsh (reuses it, or auto-downloads the official linux-x64 tarball to `~/.local/share/powershell` + symlink `~/.local/bin/pwsh`, no root) → writes `~/.local/share/applications/zcode-background.desktop` with the fully-resolved Exec. No C# launcher needed on Linux (`.desktop` runs pwsh directly). Use `-SkipPwshInstall` to forbid the auto-download.
- `zcode-background-launcher.cs` → `zcode-background-launcher.exe` (tracked build artifact, **Windows only**). Console-less C# launcher that simply spawns pwsh and passes args through.
- `assets/` — sample media (one jpg, one mp4).

## Gotchas

- **Param defaults in `zcode-background.ps1` are stale dev-machine paths** (`$MediaDirectory`, `$ImagePath` point to `E:\...`, `C:\Users\admin\...`). Never rely on them; both installers always pass resolved values. `$ZCodePath` default is now `""` → cross-platform auto-detect via `Find-ZCodeExecutable` (runs first in main; an explicitly given-but-missing path also falls back to detection).
- **ZCode is single-instance on Linux** (`zcode://` protocol lock) — a second launch exits immediately. There is no way to test against a throwaway instance; the only testable flow is the tool itself: kill existing ZCode → restart one with the debug port. Hot-reload the overlay by closing+reopening ZCode only.
- **Process name & graceful close differ per platform**: main process comm is `ZCode` on both, but children are `zcode`; `Stop-ZCodeProcesses` matches against `"ZCode","zcode"` AND resolved executable path. `CloseMainWindow()` is a no-op on Linux (`MainWindowHandle` is always 0), so Linux uses SIGTERM (`Stop-Process`) then SIGKILL (`-Force`) — Chromium/Electron saves state on SIGTERM.
- **HTTP path-traversal check in the runspace is now cross-platform**: separator from `[IO.Path]::DirectorySeparatorChar`, and case comparison is `Ordinal` on Linux vs `OrdinalIgnoreCase` on Windows. `$IsWindows` is passed into the runspace explicitly (raw `[PowerShell]::Create()` runspaces don't always expose automatic variables) — keep passing it when the param list changes.
- **Port probing uses `HttpListener` (HTTP.sys), not `TcpListener`** — on Windows apps like `codex.exe` hold HTTP.sys-level reservations that TcpListener misses (real bug `5491c51`). On Linux `HttpListener` uses a managed implementation and binds fine to high ports — same code path works.
- **Duplicated logic in the embedded runspace string** in `Start-MediaHttpServer`: the request-loop scriptblock (`_PickRandom`, MIME switch) is a string, not shared code. `Get-RandomMediaFromDirectory` + `_MediaType`/MIME tables must be kept in sync manually.
- Adding a media format means touching the extension lists in both scripts AND the MIME switches (main function + embedded runspace).
- Overlay is a JS string from `New-OverlayJavaScript`; fixed element id `zcode-background-overlay`, re-registered via `Page.addScriptToEvaluateOnNewDocument` so it survives page navigation.
- `random` mode is 1:1 image/video by design (coin-flip on type, then pick within pool), NOT proportional to file counts.
- All comments and user-facing strings are Chinese — match that convention.

## Verification

No build system, tests, or CI. Smoke-test without side effects (works on both platforms):

```powershell
pwsh -ExecutionPolicy Bypass -File ./zcode-background.ps1 `
  -ZCodePath </opt/ZCode/zcode | C:\...\ZCode.exe> -BackgroundMode image `
  -MediaDirectory ./assets -ValidateOnly
```

`-ValidateOnly` prints a JSON summary and does NOT close/restart ZCode or start servers (the recommended safe check; the normal run always kills & restarts ZCode). Omitting `-ZCodePath` exercises auto-detection.

Linux installer (creates/replaces `~/.local/share/applications/zcode-background.desktop`; auto-installs pwsh if missing):

```powershell
pwsh -ExecutionPolicy Bypass -File ./install-zcode-background-linux.ps1
```

Windows installers/environment remain as before (see `install-zcode-background-shortcut.ps1` credits: requires ZCode on the box; also rebuilds the launcher.exe via the system .NET Framework `csc.exe` — **not** the dotnet SDK, keep `zcode-background-launcher.cs`'s ~113-line C# subset compatible, and don't commit a stale exe after a `.cs` edit).

Full E2E (verified on this box): run the `.desktop` Exec → media server on 9231 (`/health`, `/random`, Range 206 all confirmed), overlay element confirmed in DOM via CDP (`VIDEO | http://127.0.0.1:9231/sample-background.mp4 | opacity=0.15`), and closing ZCode makes the runner exit and free port 9231 with no orphans.