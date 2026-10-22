# plezy-bert

A modified build of [Plezy](https://github.com/edde746/plezy), the open-source Plex and Jellyfin client, by
edde746 and its contributors.

This copy adds a set of Companion Remote commands so that an external controller can drive the app: play or shuffle
a title, seek, set the volume, pick audio and subtitle tracks, mark items watched or unwatched, skip intros and
credits, and read what is playing. It also adds a few playback and detail-page changes.

## Licence

Plezy is licensed under the GNU General Public License v3.0, and so is this modified version. See [LICENSE](LICENSE).
The files in this repository are the complete source of the published builds. They were modified from upstream
Plezy; the upstream project is at https://github.com/edde746/plezy.

## Releases

Each release carries these files (`<version>` is this fork's own version, for example `0.0.2`):

| File | What it is |
|---|---|
| `PlezyFork-<version>-setup.exe` | The Windows installer. It installs beside the official Plezy and can offer to remove it (your settings stay, and a copy is saved first). |
| `PlezyFork-<version>-silent-setup.exe` | The same app, installed without a single question: made for unattended machines (below). |
| `PlezyFork-<version>-phone-arm64-v8a.apk` | Android phones. |
| `PlezyFork-<version>-tv-armeabi-v7a.apk` | Android TV and Google TV devices. |
| `appcast.xml`, `android.json` | What the app reads to find its own updates. |
| `PlezyFork-<version>-SHA256SUMS.txt` | The SHA-256 of every file above, in `sha256sum` format (`sha256sum -c --ignore-missing` checks a download). |

Tags are `v<x.y.z>`. A version whose last number is above 0 (`0.0.2`) is a beta and is marked as a pre-release;
`x.y.0` is a release. Betas and releases are builds of the same app and install over each other. To follow the betas,
take the highest `vX.Y.Z` tag across all releases, pre-releases included.

### The silent installer

```
PlezyFork-<version>-silent-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /UPDATECHECKS=off
```

- It installs for the current user only, never asks for administrator rights, shows no page and asks nothing, and
  never touches the official Plezy.
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

## Building

The same as upstream Plezy: Flutter (the version pinned in `pubspec.yaml`), then `flutter pub get` and
`flutter build windows` or `flutter build apk --split-per-abi`.
