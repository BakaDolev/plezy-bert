# Plezy Fork

A modified build of [Plezy](https://github.com/edde746/plezy), the open-source Plex and Jellyfin client by edde746
and its contributors, for Windows, Android phones and Android TV / Google TV.

It adds Companion Remote commands so an external controller can drive the app, updates itself, and carries a set of
playback fixes. It is not made by the Plezy authors, and it is not affiliated with Plex.

[**Download the latest release**](../../releases) · [What each file is](#releases) · [Remote commands](#companion-remote-commands)

## What's different from Plezy

**Remote control.** Plezy's Companion Remote gains commands for an external controller: play or shuffle a specific
title, jump to a position, set the volume, pick audio and subtitle tracks by language, set the quality, the audio
output device, A/V sync, speed and zoom, mark items watched or unwatched, skip intros and credits, and go fullscreen.
Play, pause, skip intro / credits and set volume work from a controller too. The app reports what is playing, its
tracks and volume, so a controller can confirm a command landed. [The full list](#companion-remote-commands).

**Updates itself.** When Plezy opens (or from About > Check for updates) it offers the next build in its own window:
Install, Later or Skip. Never while something plays. Every update is signature-checked before it installs. Turn on
About > Beta updates to get new builds first.

**Windows.** An installer that puts Plezy Fork beside the official Plezy, and can remove the official one for you
(your settings stay, and a copy is saved first). A [silent installer](#the-silent-installer) for unattended machines.

**Android phones.** Turn the screen off and the audio keeps playing, like a podcast, with lock-screen controls. Intros
still skip, each episode uses its own intro and credits times, long sessions use less data so the audio outlasts
network gaps, and unlocking picks the stream back up where it was.

**Android TV.** Waking from the screensaver goes straight back to your paused show. The actor page fits the screen.

**Everywhere.** A full actor page (bio, known for, filmography) and a page for each episode. A device left paused
no longer drags your progress back after you watched further on another one: pressing play there asks whether to go
on from the newer spot.

## Installing

- **Windows:** run `PlezyFork-<version>-setup.exe`. Your Plex sign-in and settings carry over from the official
  Plezy on the same computer. It isn't code-signed, so Windows SmartScreen may warn the first time: choose
  *More info* > *Run anyway*.
- **Android phone:** open `PlezyFork-<version>-phone-arm64-v8a.apk` on the phone and allow your browser or file app to
  install apps when Android asks.
- **Android TV / Google TV:** install `PlezyFork-<version>-tv-armeabi-v7a.apk` with a sideloading app or
  `adb install`.
- **On Android, uninstall the official Plezy first** if it is there: Android doesn't install an app signed by someone
  else over it. You sign in again once. An older Plezy Fork updates in place, settings and sign-in kept.

After that, updates arrive in the app. On Android, allow Plezy to install apps once, the first time it updates. Betas
come only with About > Beta updates turned on.

## Releases

Each release carries these files (`<version>` is this fork's own version, for example `0.0.2`):

| File | What it is |
|---|---|
| `PlezyFork-<version>-setup.exe` | The Windows installer. |
| `PlezyFork-<version>-silent-setup.exe` | The same app, installed without a single question: made for unattended machines (below). |
| `PlezyFork-<version>-phone-arm64-v8a.apk` | Android phones. |
| `PlezyFork-<version>-tv-armeabi-v7a.apk` | Android TV and Google TV devices. |
| `appcast.xml`, `android.json` | What the app reads to find its own updates. |
| `checksums-<version>.txt` | The SHA-256 of every file above, in `sha256sum` format (`sha256sum -c --ignore-missing` checks a download). In 0.0.1 it is `PlezyFork-0.0.1-SHA256SUMS.txt`. |

Tags are `v<x.y.z>`. A version whose last number is above 0 (`0.0.2`) is a beta and is marked as a pre-release;
`x.y.0` is a release. Betas and releases are builds of the same app and install over each other. To follow the betas,
take the highest `vX.Y.Z` tag across all releases, pre-releases included.

### The silent installer

```
PlezyFork-<version>-silent-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /UPDATECHECKS=off
```

- It installs for the current user only, never asks for administrator rights, shows no page and asks nothing, and
  never touches the official Plezy. Double-clicked, it shows only its progress bar.
- A running Plezy Fork is asked to close (and ended if it is still open 10 seconds later), then started again once
  the update is in. One that was not running stays closed. `/NORUN=1` never starts it.
- `/UPDATECHECKS=off` stops the app from looking for updates on its own, for this user; the About screen's button
  still checks. `/UPDATECHECKS=on` turns that back on. Both installers take this switch.
- Exit codes: `0` installed, or this exact build was already installed (nothing done); `10` a newer build is installed
  (nothing done); `11` the installed copy is installed for all users and needs an administrator (nothing done); any
  other code: the install failed.
- Every run leaves `%LOCALAPPDATA%\Plezy Fork\install-status.json`, always replaced whole (never half-written):

```json
{
  "run_id": "20261022-061512-4242",
  "result": "installed",
  "exit_code": 0,
  "started": "2026-10-22T06:15:12",
  "finished": "2026-10-22T06:15:40",
  "from_version": "0.0.2",
  "from_build": 181,
  "to_version": "0.0.3",
  "to_build": 182,
  "plezy_was_open": false,
  "reopened": false,
  "update_checks": "off",
  "installer_pid": 4242,
  "log": "...\\Temp\\Setup Log 2026-10-22 #001.txt"
}
```

`result` is `running` while it works, then `installed`, `current` (this build was there already), `refused` (a newer
one is) or `failed`. Times are local. `from_version` and `from_build` are `null` on a first install; `finished` and
`exit_code` are `null` while it runs, and `exit_code` is `null` when Setup itself failed (the process's exit code still
says how). `installer_pid` is the Setup process that writes the file, not the `.exe` that was started: wait for that
`.exe` to exit, then read the file. `log` is Setup's own log of the run.

## Companion Remote commands

These ride on Plezy's own Companion Remote connection, so a controller connects the way Plezy's remote does (signed
in to the same Plex Home). Each command is a frame `{"t": <number>, "d": {...}}`. The new numbers come after
Plezy's own, and an unmodified Plezy ignores them.

| `t` | Command | `d` | What it does |
|---|---|---|---|
| 7 / 8 / 9 | `play` / `pause` / `playPause` | none | Play, pause (both idempotent), or toggle |
| 15 / 16 | `skipIntro` / `skipCredits` | none | Jump past the intro or credits |
| 20 | `volumeSet` | `{"volume"}` | Set the volume |
| 39 | `syncState` | (sent by the app) | What is playing: title, position, tracks, volume and more |
| 40 | `playMedia` | `{"serverId", "ratingKey", "offset"}` | Play a library item, optionally from `offset` ms |
| 41 | `seekTo` | `{"positionMs"}` | Jump to a position |
| 42 | `shuffleMedia` | `{"serverId", "ratingKey"}` | Shuffle a show |
| 43 / 44 | `markWatched` / `markUnwatched` | `{"serverId", "ratingKey"}` | Mark an item, or a whole series, watched or unwatched |
| 45 | `setSubtitleTrack` | `{"off"}`, `{"index"}`, `{"id"}` or `{"language", "codec", "external"}` | Pick a subtitle track |
| 46 | `setAudioTrack` | `{"id"}`, `{"index"}` or `{"language"}` | Pick an audio track |
| 47 | `setQuality` | `{"quality"}` (`"1080p"`, `"original"`, ...) or `{"index"}` | Set the quality |
| 48 | `setAudioDevice` | `{"name"}`, `{"index"}` or `{"auto": true}` | Pick the audio output device |
| 49 / 50 | `setSubtitleSync` / `setAudioSync` | `{"deltaMs"}`, `{"offsetMs"}` or `{"reset": true}` | Nudge or set the sync |
| 51 | `setSpeed` | `{"speed"}`, `{"delta"}` or `{"reset": true}` | Playback speed (0.5× to 3×) |
| 52 | `setSecondarySubtitleTrack` | `{"off"}`, `{"index"}` or `{"language"}` | A second subtitle beside the first |
| 53 | `setZoom` | `{"scale"}`, `{"delta"}`, `{"reset"}` or `{"fit"}` | Fit or zoom the picture |
| 54 | `setFullscreen` | `{"enabled"}` | Fullscreen on or off (desktop) |

`serverId` is the Plex server's machine identifier, `ratingKey` the item's library key.

## Building

The same as upstream Plezy: Flutter (the version pinned in `pubspec.yaml`), then `flutter pub get` and
`flutter build windows` or `flutter build apk --split-per-abi`.

## Licence

Plezy is licensed under the GNU General Public License v3.0, and so is this modified version. See [LICENSE](LICENSE).
The files in this repository are the complete source of the published builds. They were modified from upstream
Plezy; the upstream project is at https://github.com/edde746/plezy.
