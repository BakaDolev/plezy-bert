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

## Building

The same as upstream Plezy: Flutter (the version pinned in `pubspec.yaml`), then `flutter pub get` and
`flutter build windows` or `flutter build apk --split-per-abi`.
