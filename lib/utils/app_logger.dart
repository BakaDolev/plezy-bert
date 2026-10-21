import 'dart:collection';

import 'package:logger/logger.dart';

import 'file_log_sink.dart';
import 'log_redaction_manager.dart';

/// Redacts sensitive information from log text.
///
/// Exposed so the startup path can re-run redaction over lines that were
/// buffered before [LogRedactionManager] learned the server tokens — those
/// predate registration and would otherwise reach the log file unredacted.
String redactLogText(String message) => LogRedactionManager.redact(message);

/// Represents a single log entry stored in memory
class LogEntry {
  final DateTime timestamp;
  final Level level;
  final String message;
  final Object? error;

  /// Redacted at construction, like [message] and [error]. Held as a String
  /// rather than a StackTrace because a redacted trace is no longer the
  /// original object — and an unredacted one must not reach the log file.
  final String? stackTrace;

  const LogEntry({required this.timestamp, required this.level, required this.message, this.error, this.stackTrace});

  /// Estimate the memory size of this log entry in bytes
  int get estimatedSize {
    int size = 0;
    size += 8;
    size += 4;
    size += message.length * 2;
    if (error != null) {
      size += error.toString().length * 2;
    }
    if (stackTrace != null) {
      size += stackTrace.toString().length * 2;
    }
    return size;
  }
}

/// Render one entry the way the in-app log viewer renders it, so a log file and
/// the viewer's "copy" button produce interchangeable text.
///
/// The per-line stamp is time-only, matching the viewer; the calendar date
/// lives in the log file's name and header.
String formatLogEntry(LogEntry entry) {
  final t = entry.timestamp;
  final stamp =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
  final buffer = StringBuffer('[$stamp] [${entry.level.name.toUpperCase()}] ${entry.message}');
  if (entry.error != null) {
    // Info/debug calls pass ordinary data through the logger's `error:` slot,
    // so only warnings and up are labelled as errors — a grep for "Error:"
    // should find problems, not noise.
    final label = entry.level >= Level.warning ? 'Error' : 'Details';
    buffer.write('\n$label: ${entry.error}');
  }
  if (entry.stackTrace != null) {
    buffer.write('\nStack trace:\n${entry.stackTrace}');
  }
  return buffer.toString();
}

/// The session log header's version label. Windows reports no build number, so
/// the brackets are dropped rather than printed empty.
String formatLogVersion(String version, String buildNumber) =>
    buildNumber.isEmpty ? version : '$version ($buildNumber)';

/// In-memory log store with a circular buffer.
///
/// Fed by [MemoryAwareLogPrinter.log()]; console output goes through the
/// logger's default [ConsoleOutput].
class MemoryLogOutput {
  static const int maxLogSizeBytes = 5 * 1024 * 1024;
  static final ListQueue<LogEntry> _logs = ListQueue<LogEntry>();
  static int _currentSize = 0;

  /// Append [entry], evicting the oldest entries once the buffer exceeds
  /// [maxLogSizeBytes] — O(1) with ListQueue.
  static void add(LogEntry entry) {
    _logs.add(entry);
    _currentSize += entry.estimatedSize;
    while (_currentSize > maxLogSizeBytes && _logs.isNotEmpty) {
      _currentSize -= _logs.removeFirst().estimatedSize;
    }
  }

  static List<LogEntry> getLogs() => _logs.toList().reversed.toList();

  static void clearLogs() {
    _logs.clear();
    _currentSize = 0;
  }
}

/// Custom log printer that also stores error and stack trace information
class MemoryAwareLogPrinter extends LogPrinter {
  final LogPrinter _wrappedPrinter;

  MemoryAwareLogPrinter(this._wrappedPrinter);

  @override
  List<String> log(LogEvent event) {
    final message = LogRedactionManager.redact(event.message.toString());
    final error = event.error != null ? LogRedactionManager.redact(event.error.toString()) : null;
    // The entry keeps the redacted trace as text (a redacted trace is no longer
    // the original object); the wrapped printer still wants a StackTrace, so
    // give it one rebuilt from the redacted text — never the original.
    final redactedStackTrace = event.stackTrace == null
        ? null
        : LogRedactionManager.redact(event.stackTrace.toString());
    final wrappedStackTrace = redactedStackTrace == null ? null : StackTrace.fromString(redactedStackTrace);

    final logEntry = LogEntry(
      timestamp: DateTime.now(),
      level: event.level,
      message: message,
      error: error,
      stackTrace: redactedStackTrace,
    );

    // The file always records every event this printer sees (down to debug) —
    // that is the fork's whole purpose. The in-memory viewer buffer and console
    // below honor [_displayLevel], so e.g. setLoggerLevel(false) keeps debug
    // lines out of the in-app viewer and console while the file still has them.
    FileLogSink.instance.writeLine(formatLogEntry(logEntry));

    if (event.level.value < _displayLevel.value) {
      return const [];
    }

    MemoryLogOutput.add(logEntry);

    return _wrappedPrinter.log(
      LogEvent(event.level, message, time: event.time, error: error, stackTrace: wrappedStackTrace),
    );
  }
}

/// Custom production filter that respects our level setting even in release mode
class ProductionFilter extends LogFilter {
  Level _currentLevel = Level.debug;

  void setLevel(Level level) {
    _currentLevel = level;
  }

  bool isEnabledFor(Level level) => level.value >= _currentLevel.value;

  @override
  bool shouldLog(LogEvent event) => isEnabledFor(event.level);
}

final _productionFilter = ProductionFilter();

/// Whether [appLogger].d would actually emit.
///
/// Dart builds a log call's message argument *before* the filter can drop it,
/// so a `.d()` whose message costs real work — string interpolation in a loop,
/// `redact()`, `jsonEncode`, a collection `toString()` — pays that cost on
/// every call in release, where the line is then discarded. Guard those call
/// sites with this; plain constant or cheap messages need no guard.
bool get debugLoggingEnabled => _productionFilter.isEnabledFor(Level.debug);

/// Level gating the in-app log viewer buffer ([MemoryLogOutput]) and console
/// output. The session log FILE ignores this and always records every event
/// (see [MemoryAwareLogPrinter]); this only controls what the in-app viewer and
/// console show. Set via [setLoggerLevel].
Level _displayLevel = Level.debug;

/// Centralized logger instance for the application.
///
/// Usage:
/// ```dart
/// import 'package:plezy/utils/app_logger.dart';
///
/// appLogger.d('Debug message');
/// appLogger.i('Info message');
/// appLogger.w('Warning message');
/// appLogger.e('Error message', error: e, stackTrace: stackTrace);
/// ```
///
/// Non-final so tests can swap in a recording logger.
Logger appLogger = Logger(
  printer: MemoryAwareLogPrinter(SimplePrinter()),
  filter: _productionFilter,
  level: Level.debug,
);

/// Sets the log DISPLAY level (in-app viewer + console) from [debugEnabled].
///
/// Fork change: this no longer gates the session log FILE. [ProductionFilter]
/// stays at debug so [MemoryAwareLogPrinter] sees every event and always
/// records it to the file (see [FileLogSink]) — companion-remote and playback
/// diagnostics are all at debug and must never be dropped from the file. What
/// [debugEnabled] controls is [_displayLevel]: with debug off, the in-app viewer
/// and console fall back to info while the file still keeps the debug lines.
///
/// [debugEnabled] also drives the *native mpv* log level
/// (`video_player_screen.dart`), deliberately left at `warn` here because mpv
/// verbose is a firehose during playback. The active mpv level is recorded in the
/// log file header so a reader knows what is missing.
void setLoggerLevel(bool debugEnabled) {
  _displayLevel = debugEnabled ? Level.debug : Level.info;
  _productionFilter.setLevel(Level.debug);
}
