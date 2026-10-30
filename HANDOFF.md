# Handoff: Sitch — Snapline merge + Windows feature pass

Branch: `claude/trusting-maxwell-80vjyb`. Nothing on it has reached GitHub (the account was flagged);
the commits live in this local clone (originally from `sitch-full.bundle`, kept at
`C:\Users\cxpan\sitch-full.bundle`). `origin` already points at `https://github.com/flexlm307/Sitch`;
when the account is back: `git push -u origin claude/trusting-maxwell-80vjyb`.

## Commits on the branch (oldest first, after `main` = `d2cb8e0`)

| Commit | What |
|---|---|
| `c3b0287` | Windows: Snapline's screenshot line merged as `windows/Sitch/Shelf` |
| `c98842c` | Mac: line merged as SwiftPM target `mac/Sources/SitchShelf` — **never compiled** |
| `e5c26cb` | TEMPORARY: CI also builds `claude/**` branches — **revert before merging** |
| `0dca2b2` | Docs + Snapline/Tendedero MIT notice in `LICENSE` |
| `126a5c4` | Windows: nullable warning fix in the line's clipboard watcher |
| `da0ab74` | Windows: Chinese UI (`Shell/Loc.cs`), MediaMini compression, element snapping in capture |
| `e03b4df` | Windows: magnifier + colour picker, editor OCR (RapidOCR), full-size taskbar icon |
| `0fa671e` | Windows: pin captures on top of the screen |
| `0e45e10` | Windows: scrolling capture |
| `7ad2054` | Windows: record a region to GIF / MP4 with FFmpeg |
| `1c5355e` | `LICENSE`: evan-ocr (MIT) credit for the stitcher and magnifier approach |

Everything after `0dca2b2` is **Windows only**. `docs/ARCHITECTURE.md` describes each piece (search for
Element snapping, Language, MediaMini, OCR, Magnifier, Pins, Scrolling capture, Recording).

## Windows features added (all user-tested on Windows 11, two monitors at 125% and 150%)

- **Chinese UI**: Settings > General > Language (System / English / 中文), applies after restart. English
  strings are the keys in `Shell/Loc.cs` (`Loc.T/F`, `{sh:T '…'}` in XAML); the line has its own
  `Shelf/UI/Strings.cs` (en/zh/ar, "auto" follows Sitch).
- **Element snapping**: region capture highlights the UI Automation element under the pointer; wheel steps
  out/in; click captures it. Keys on a target: **F3** pin, **S** scrolling capture, **R** record.
- **Magnifier**: 15×15 px zoom + colour; **C** copies HEX, **Shift+C** RGB.
- **OCR**: editor "Extract text" (Ctrl+Shift+O), the line's "Copy text", a pin's menu. Engine setting:
  Windows built-in or **RapidOCR** (`pip install rapidocr`; persistent Python worker, falls back to Windows).
- **Pins**: F3 (overlay / editor), Ctrl+Alt+P (clipboard image), tray, the line's "Pin to screen".
- **Scrolling capture**: Ctrl+Alt+Shift+S or tray or S; user scrolls, Done routes the long image.
- **Recording**: Ctrl+Alt+Shift+R or tray or R; GIF (12 fps, two-pass palette) or MP4 (30 fps), via FFmpeg.
- **MediaMini**: optional; after Save / Save As / quick-save runs `<folder>/cli.py optimize … --in-place`.
- **Restore as Markdown (MinerU)**: editor "MD" (Ctrl+Shift+M), pin and line menus; shown when Settings >
  Editor has the MinerU environment folder (here `%USERPROFILE%\.local\mineru-3.4.4`, an ASCII junction to
  `Anki卡片制作\.tools\mineru-3.4.4`). Persistent `mineru-api`: ~30 s first run, ~3 s after; tables come
  back as HTML tables, figures as `images/`.

External tools are found on the PATH (`python`, `ffmpeg`); none ship with Sitch. On this PC: Python 3.12
with `rapidocr` 3.10, FFmpeg 9.0 (winget Gyan.FFmpeg), MediaMini at `C:\Users\cxpan\Tools\MediaMini`.
The user's own settings (`%APPDATA%\Sitch\settings.json`) have Language `zh`, OcrEngine `RapidOCR`,
MediaMini on.

## How things were verified

No test project exists (see `CLAUDE.md`). Checks were done with throwaway harnesses (not in the repo)
that reference `Sitch.csproj` and call the real code: the stitcher pixel-compared against a known page
and OCR-checked on real screen scrolling; recordings probed with ffprobe (frames, fps, duration); pin
and frame window sizes measured with GetWindowRect per monitor DPI; UI text read through UI Automation.
The user then exercised each feature by hand.

Known limits: scrolling capture is downward only and expects whole-pixel scrolling (browsers, editors);
the scrollbar appears in every slice. Electron apps without accessibility expose only their window to
snapping. Windows' own OCR is poor on English when only the Chinese OCR pack is installed.

## Next steps

1. **Mac** (needs macOS): `cd mac && swift build && swift test`, fix compile errors in
   `Sources/SitchShelf` and the files `c98842c` touched, then `./scripts/smoke-test.sh "$(swift build
   --show-bin-path)/Sitch"` and check the line with `./scripts/build-app.sh` (incl. Inbox mode restoring
   the macOS screenshot settings on quit). The Windows-only features above have no Mac counterpart yet —
   decide which to port.
2. Revert `e5c26cb`, then merge into `main` (solo repo: commits go to `main`). Ask the user first.
3. Push when the GitHub account is restored; release only via the tag flow in `CLAUDE.md`.
