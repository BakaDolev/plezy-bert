/// Content for the in-app fork changelog screen. Plain English, newest first.
///
/// Fork-local (this file does not exist upstream). Update the `This fork` section
/// whenever a fork build ships (its version comes from the release build).
library;

class ChangelogEntry {
  final String date; // ISO YYYY-MM-DD, or a range label
  final String title;
  final List<String> changes;
  const ChangelogEntry({required this.date, required this.title, required this.changes});
}

class ChangelogSection {
  final String heading;
  final String subtitle;
  final List<ChangelogEntry> entries;
  const ChangelogSection({required this.heading, required this.subtitle, required this.entries});
}

/// The two histories shown in the app: what the fork added, and what the stock
/// Plezy it is built on brought.
const List<ChangelogSection> forkChangelog = [
  ChangelogSection(
    heading: 'This fork',
    subtitle: 'What the voice-control fork adds on top of Plezy',
    entries: [
      ChangelogEntry(
        date: '2026-10-22',
        title: '0.0.3 (beta): every version in this changelog',
        changes: [
          'This changelog now lists every version of the fork, from 0.0.1 on, and each new version adds its own entry.',
        ],
      ),
      ChangelogEntry(
        date: '2026-10-22',
        title: '0.0.2 (beta): the silent installer stays silent',
        changes: [
          'Double-clicking the silent installer shows only its progress bar; it no longer stops on a "Ready to Install" page.',
          'The first version delivered inside the app: 0.0.1 offered it on Windows and Android, one click each.',
        ],
      ),
      ChangelogEntry(
        date: '2026-10-22',
        title: '0.0.1 (beta): it updates itself, and a real Windows installer',
        changes: [
          'Plezy Fork updates itself: when it opens, or from About > Check for updates, it offers the next build in its own window (Install, Later or Skip), never while something plays. Every update is signature-checked before it installs.',
          'About > Beta updates: take each beta as it comes out, or only full releases.',
          'Windows: an installer that puts Plezy Fork beside the official Plezy (and can remove the official one, keeping your settings), and a silent installer for unattended machines.',
          'The fork has its own version number, shown in About.',
        ],
      ),
      ChangelogEntry(
        date: '2026-10-13',
        title: 'Caught up to Plezy 2.23.0',
        changes: [
          'Rebuilt on the latest Plezy (up two releases from 2.21.0) with every fork feature replayed on top.',
          'Screen-off listening keeps going past the "Up next" countdown, which Plezy now pauses in the background, and through the parts of a movie split across several files.',
          'Unlocking the phone no longer reloads an episode that already finished, or restarts a stream you stopped from the Plex dashboard.',
          'A voice seek stays inside the title, and a voice sync change shows in the sync setting and stays with that episode.',
        ],
      ),
      ChangelogEntry(
        date: '2026-10-13',
        title: 'Intros skip with the screen off, the TV wakes straight back into your show',
        changes: [
          'Screen-off listening skips intros again, and every episode uses its own intro and credits times, not those of the episode you started on.',
          'On the TV, waking from the screensaver goes straight back to your paused show instead of reloading it.',
        ],
      ),
      ChangelogEntry(
        date: '2026-10-10',
        title: 'Screen-off audio through the night, the full actor page on TV',
        changes: [
          'Screen-off listening no longer dies about a minute after an episode that ends without a credits marker: the "Up next" countdown no longer drops the background media service.',
          'Unlocking the phone after the stream lost its connection with the screen off no longer leaves it buffering for minutes: the stream is rebuilt where you left off.',
          'On the TV, opening an actor from a movie or show page shows the full actor page (bio, Known For, filmography), not just your library titles.',
        ],
      ),
      ChangelogEntry(
        date: '2026-09-28',
        title: 'Smoother screen-off audio, a TV actor page that fits',
        changes: [
          'Turning the phone screen off no longer cuts the audio for a few seconds: the switch to the low-data stream now waits for the next episode.',
          'On the TV the actor page fits the screen: a smaller header, compact library cards, and a filmography list whose last rows stay on screen.',
        ],
      ),
      ChangelogEntry(
        date: '2026-09-24',
        title: 'Caught up to Plezy 2.21.0',
        changes: [
          'Rebuilt on the latest Plezy (up five releases from 2.16.0) with every fork feature replayed on top.',
          'A voice command sent right after a title opens (e.g. "play X at volume 30") no longer gets lost while the player is still starting.',
          'Setting the volume by voice now shows the on-screen volume pill, like any other volume change.',
          'The app stops logging a warning every few seconds when no voice controller is connected.',
        ],
      ),
      ChangelogEntry(
        date: '2026-09-15 – 09-21',
        title: 'Actor and episode pages, steadier background audio',
        changes: [
          'A full actor page (bio, known-for, filmography) and a page for each episode, on every device.',
          'On the phone, screen-off audio keeps playing with working lock-screen controls, closing picture-in-picture pauses, and long listening sessions use less data so the audio lasts through network hiccups.',
        ],
      ),
      ChangelogEntry(
        date: '2026-08-20',
        title: 'Caught up to Plezy 2.16.0, and this changelog',
        changes: [
          'Rebuilt on the latest Plezy (up three releases from 2.13.0) with the whole voice-control command set replayed on top.',
          'Added this in-app changelog and a "Voice-control fork" marker on the About screen, so you can tell this build from stock Plezy.',
          'Kept the session log complete while the in-app log viewer follows your debug setting again.',
        ],
      ),
      ChangelogEntry(
        date: '2026-08-14',
        title: 'Make it fullscreen by voice',
        changes: [
          'An absolute "go fullscreen / leave fullscreen" command, so it can\'t flip the wrong way and doesn\'t steal focus.',
          'Fixed desktop shortcuts so they always launch the current build.',
        ],
      ),
      ChangelogEntry(
        date: '2026-08-11',
        title: 'Keep playing on the phone with the screen off',
        changes: [
          'On a phone, video used to die when backgrounded; now the audio keeps playing like a podcast, with lock-screen controls. Phone only.',
        ],
      ),
      ChangelogEntry(
        date: '2026-08-10',
        title: 'Subtitles land on the right language on the TV',
        changes: [
          'Asking for a subtitle language during a source switch now settles on the correct track instead of flickering onto the wrong one.',
        ],
      ),
      ChangelogEntry(
        date: '2026-07-22 – 07-28',
        title: 'The voice command set (why this fork exists)',
        changes: [
          'Play a specific title, jump to a position, shuffle a show, mark watched / unwatched.',
          'Pick a subtitle or audio track by language, set quality, pick the audio output device, nudge A/V sync, set speed, zoom the picture.',
          'Fixed play / pause, skip intro / credits and set volume, which were defined but did nothing in stock Plezy.',
          'The app now reports now-playing, tracks, volume and more, so a controller can confirm a command actually landed.',
        ],
      ),
    ],
  ),
  ChangelogSection(
    heading: 'Plezy (upstream)',
    subtitle: 'The stock app this build is based on — highlights from 2.17 → 2.23',
    entries: [
      ChangelogEntry(
        date: 'Plezy 2.17 – 2.20',
        title: 'Playback',
        changes: [
          'Android now plays through mpv by default: 10-bit/HDR, Dolby Vision on Google TV, audio passthrough.',
          'Playback recovers: a Retry screen on a failed open, failures reported in seconds, and Back reliably leaves the player.',
          'Pick audio and subtitle tracks before pressing Play; smoother display matching on 90/120 Hz screens.',
        ],
      ),
      ChangelogEntry(
        date: 'Plezy 2.17 – 2.20',
        title: 'Everything else',
        changes: [
          'Live TV recording (Jellyfin/Emby) and guide search; watch-together host transfer.',
          'Account preferences stored on the server so they follow you between devices; a reorganised Settings screen.',
          'Windows remembers where a snapped window sits, and starts faster.',
        ],
      ),
      ChangelogEntry(
        date: 'Plezy 2.21',
        title: 'Latest release',
        changes: [
          'Library filters with multiple values, exclusions and ranges; grouping, sorting and filters for downloads.',
          'An on-screen pill for every volume change, and a "shuffle starts at the beginning" setting.',
          'Image subtitles no longer draw a box behind them; non-16:9 video is letterboxed on Android.',
          'Ctrl+R / Cmd+R refreshes the current page on desktop.',
        ],
      ),
      ChangelogEntry(
        date: 'Plezy 2.22',
        title: 'Playback and search',
        changes: [
          'Search finds actors and directors.',
          'DTS plays as surround instead of silence on TVs without DTS, and audio no longer drops out on low-RAM TV boxes.',
          '4K HDR plays smoothly on weaker TV boxes, and Windows matches 23.976, 29.97 and 59.94 Hz displays.',
          'Play, pause, seek and skip from the voice remote also control music.',
        ],
      ),
      ChangelogEntry(
        date: 'Plezy 2.23',
        title: 'Latest release',
        changes: [
          'Movies split across several files play as one title, and a stream stopped from the Plex dashboard stays stopped.',
          'Streams no longer stall at start when the network ignores IPv6 lookups, and slow servers are waited on instead of reported unreachable.',
          'Enter skips the intro on desktop; phone detail pages show IMDb, Rotten Tomatoes and TMDB ratings.',
          'Downloads resume where they stopped on Android, group by collection, and can be retried in bulk.',
        ],
      ),
    ],
  ),
];
