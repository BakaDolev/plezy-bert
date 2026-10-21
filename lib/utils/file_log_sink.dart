import 'dart:convert';
import 'dart:io';

/// Writes one log file per app session.
///
/// Deliberately knows nothing about `LogEntry`, log levels or redaction: it
/// takes already-formatted lines. That keeps it testable without Flutter or
/// path_provider, and keeps formatting decisions in one place (`app_logger`).
///
/// Two properties drive the whole design:
///
/// * **Writes are synchronous.** A buffered `IOSink` or a background isolate
///   holds the tail of the log in Dart-side memory, which dies with the
///   process — exactly the case this file exists to capture. A sync write hands
///   the bytes to the OS, which outlives the process.
/// * **Nothing here may throw.** This instruments the app; it must never be the
///   reason the app fails. Every failure path degrades to "no file" and returns.
class FileLogSink {
  FileLogSink({
    this.maxSessionFiles = 10,
    this.maxBytesPerFile = 10 * 1024 * 1024,
    this.maxBufferedLines = 2000,
  });

  /// The app-wide sink. Inert until [start] resolves a directory.
  static final FileLogSink instance = FileLogSink();

  /// Session files kept on disk, including the one about to be written.
  final int maxSessionFiles;

  /// Byte cap for a single file before it rolls. A session is therefore
  /// bounded at roughly twice this: the live file plus one rollover.
  final int maxBytesPerFile;

  /// Cap on lines held while waiting for [start].
  final int maxBufferedLines;

  static const String _filePrefix = 'plezy-';
  static const String _fileSuffix = '.log';

  /// Lines logged before the log directory resolved. `getApplicationSupport
  /// Directory()` is async but `appLogger` is a synchronous global, so without
  /// this the startup window — a prime debugging target — is what gets lost.
  final List<String> _pending = <String>[];
  int _droppedBeforeStart = 0;

  File? _file;
  RandomAccessFile? _handle;
  int _bytesWritten = 0;
  bool _started = false;

  /// Whether lines are currently reaching a file.
  bool get isActive => _handle != null;

  /// Begin writing into [directory] as [fileName].
  ///
  /// Prunes older session files, then replays anything buffered so far.
  /// [lateRedact] is applied to buffered lines only: those predate
  /// `LogRedactionManager` learning the server tokens, so they are re-redacted
  /// here, once registration has happened. Live lines were already redacted by
  /// the printer.
  ///
  /// Safe to call once; later calls are ignored.
  Future<void> start(
    Directory directory, {
    required String fileName,
    String? header,
    String Function(String)? lateRedact,
  }) async {
    if (_started) return;
    _started = true;

    try {
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
      _pruneOldSessions(directory);
      final file = File('${directory.path}${Platform.pathSeparator}$fileName');
      _handle = file.openSync(mode: FileMode.writeOnlyAppend);
      _file = file;
      _bytesWritten = file.existsSync() ? file.lengthSync() : 0;
    } catch (_) {
      // No log file this session. The in-memory buffer still works, and the
      // app carries on as if this feature did not exist.
      _handle = null;
      _file = null;
      _pending.clear();
      _droppedBeforeStart = 0;
      return;
    }

    if (header != null && header.isNotEmpty) {
      _writeRaw(header);
    }
    if (_droppedBeforeStart > 0) {
      _writeRaw('... $_droppedBeforeStart earlier line(s) dropped before the log file opened');
    }
    for (final line in _pending) {
      _writeRaw(lateRedact == null ? line : lateRedact(line));
    }
    _pending.clear();
    _droppedBeforeStart = 0;
  }

  /// Append one formatted line. Never throws, never awaits.
  void writeLine(String line) {
    if (_handle == null) {
      // After a failed start there is nowhere to put this; buffering it would
      // grow without bound for the life of the process.
      if (_started) return;
      _pending.add(line);
      if (_pending.length > maxBufferedLines) {
        _pending.removeAt(0);
        _droppedBeforeStart++;
      }
      return;
    }
    _writeRaw(line);
  }

  /// Flush and release the file handle.
  Future<void> close() async {
    final handle = _handle;
    _handle = null;
    _file = null;
    try {
      handle?.flushSync();
      handle?.closeSync();
    } catch (_) {
      // Closing a already-dead handle is not worth reporting.
    }
  }

  void _writeRaw(String line) {
    final handle = _handle;
    if (handle == null) return;
    try {
      final bytes = utf8.encode('$line\n');
      // Roll *before* writing, so the line just logged is always in the live
      // file. Rolling afterwards would push the most recent output — the whole
      // reason for the cap — into the rollover.
      if (_bytesWritten > 0 && _bytesWritten + bytes.length > maxBytesPerFile) {
        _roll();
        if (_handle == null) return;
      }
      _handle!.writeFromSync(bytes);
      // Windows does not update the directory entry while a handle is open, so
      // without this the file reads 0 bytes in Explorer for the whole session
      // and looks broken. Flushing also tightens crash durability. Measured
      // volume is ~1-2 lines/second, so the syscall is not worth avoiding.
      _handle!.flushSync();
      _bytesWritten += bytes.length;
    } catch (_) {
      // A dead handle (disk full, file removed underneath us) must not take
      // the app with it. Stop writing and stay quiet.
      _closeQuietly();
    }
  }

  /// Move the live file aside and start a fresh one.
  ///
  /// Only ever one rollover exists, so a session stays bounded at two files
  /// while the newest output is always in the live file.
  void _roll() {
    final file = _file;
    if (file == null) return;
    try {
      _handle?.flushSync();
      _handle?.closeSync();
      _handle = null;

      final rolled = File(_rolledPathFor(file.path));
      if (rolled.existsSync()) {
        rolled.deleteSync();
      }
      file.renameSync(rolled.path);

      _handle = file.openSync(mode: FileMode.writeOnlyAppend);
      _bytesWritten = 0;
    } catch (_) {
      _closeQuietly();
    }
  }

  static String _rolledPathFor(String path) {
    final base = path.endsWith(_fileSuffix) ? path.substring(0, path.length - _fileSuffix.length) : path;
    return '$base.1$_fileSuffix';
  }

  /// Delete the oldest session files, leaving room for the one about to open.
  /// Only files this sink created are considered — anything else in the
  /// directory is left alone.
  void _pruneOldSessions(Directory directory) {
    try {
      final existing = directory.listSync().whereType<File>().where((file) {
        final name = file.uri.pathSegments.last;
        return name.startsWith(_filePrefix) && name.endsWith(_fileSuffix);
      }).toList();

      if (existing.length < maxSessionFiles) return;

      existing.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      final keep = maxSessionFiles - 1;
      for (final file in existing.take(existing.length - keep)) {
        try {
          file.deleteSync();
        } catch (_) {
          // A locked file just survives another session.
        }
      }
    } catch (_) {
      // An unreadable directory is not a reason to skip logging entirely.
    }
  }

  void _closeQuietly() {
    final handle = _handle;
    _handle = null;
    _file = null;
    try {
      handle?.closeSync();
    } catch (_) {
      // Nothing left to do.
    }
  }
}
