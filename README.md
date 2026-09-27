# Tune-O-Viewer

Point it at your folders and get **every file, in one flat list**, however deeply it's nested. Then search, sort, preview, tag-read, export and tidy it up, all in a Windows 95 look.

## What it does

- **Flat list of many folders at once**: add them by typing, browsing, or dropping them on the window. Folders like `.git` or `node_modules` can be skipped.
- **Any file type**: presets for audio, images, code and documents, or type your own. Clear the types to list everything.
- **Search as you type**: matches file names and music tags. `*` and `?` wildcards work.
- **Views**: Tiles (with thumbnails and album covers), Columns, List, Paths, and Details. Details has sortable, resizable and selectable columns: size, date, length, artist, album, title, track, year, bitrate and folder.
- **Group by** folder, type, artist, album or year. Click a group header to fold it.
- **Music tags without plugins**: MP3 (ID3v1/v2), FLAC, OGG Vorbis, Opus, WAV and GameCube DSP. It reads title, artist, album, track, year, length, bitrate and cover art.
- **Preview pane**:
  - play MP3, OGG and WAV (Space)
  - see pictures and album art
  - read text and code files
  - play videos (MP4, MKV, WebM, MOV, AVI and more, via the free ffmpeg), with pause and seek
  - file info for everything else
- **Export**: M3U playlists (open them in any music player) or CSV (opens in Excel).
- **Duplicate finder**: finds identical files by content, not just name. *Select Extra Copies* picks all but one of each set.
- **Convert**: pictures to PNG, JPG or WEBP (built in), and audio to MP3, WAV, OGG, FLAC or Opus (needs the free ffmpeg). Files are saved next to the originals and never overwrite anything.
- **Tidy up**:
  - **Copy To... / Move To...** toolbar buttons for the selected files
  - rename files one after another (F2)
  - copy or move the selected files into one folder, never overwriting
  - send files to the Recycle Bin
- **Fast**: the list only draws what's on screen, so hundreds of thousands of files scroll smoothly. The last scan is cached, so it opens instantly and refreshes in the background.
- **Comfort**:
  - dark mode, zoom (Ctrl +/-), and fullscreen that scales the whole UI
  - your own font (View > Font..., or drop a .ttf/.otf on the window)
  - optional UI sounds (Ctrl+M)
  - line numbers, and a tick-box select mode
  - drag to select
  - every setting is remembered

Press **F1** in the app for all keyboard shortcuts.

## Download

**[Download v1.0 from the Releases page](https://github.com/Tune-0-Matic/tune-o-viewer/releases/latest)**. It's also on itch.io: https://zfactorpsx.itch.io/tune-o-viewer (the Discord link is there too).

| System | File | How to start it |
|---|---|---|
| Windows | `Tune-O-Viewer-v1.0-Windows.zip` | unzip, double-click `Tune-O-Viewer.exe` (SmartScreen: More info > Run anyway) |
| Linux (64-bit) | `Tune-O-Viewer-v1.0-Linux.zip` | unzip, run `Tune-O-Viewer.x86_64` |
| macOS (Intel + Apple Silicon) | `Tune-O-Viewer-v1.0-macOS.zip` | unzip, right-click the app, Open (it isn't signed by Apple) |

Nothing to install. Audio conversion uses the free [ffmpeg](https://ffmpeg.org/download.html) if you have it.

To build the downloads yourself, run `python build_release.py`. It exports all three with Godot 4.7 into `builds/Tune-O-Viewer v1.0/`.

## Code

| File | What's in it |
|---|---|
| `tune_o_viewer.gd` | the app: scanning, the file records, search, sort and group, preview, export, duplicates, file actions, settings, and the Win95 theme |
| `file_view.gd` | the list widget, which draws only visible rows and handles all five views, selection, headers and thumbnails |
| `tags.gd` | reads music tags, length and cover art from file headers |

Settings, the scan cache and thumbnails live in `%APPDATA%\Godot\app_userdata\Tune-O-Viewer`.
