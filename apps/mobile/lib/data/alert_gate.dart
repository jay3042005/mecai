/// Decides which acute findings become a *notification*.
///
/// ### The bug this exists to fix
///
/// [MonitorController] deduplicated notifications on
/// `'${flag.vital}:${flag.displayValue}:${flag.severity}'` — the **value** was
/// part of the key. The watch streams at 2 Hz and SpO₂ is noisy by a percent or
/// two, so a genuinely sustained 90% arrives as 90, 89, 90, 91, 89 … Every change
/// of value was a new key, so a single ongoing episode of low blood oxygen fired a
/// fresh max-importance alarm roughly twice a second, indefinitely.
///
/// That is not a cosmetic problem. An alarm that repeats forever is an alarm the
/// user silences or ignores, and the next one — the one that matters — is silenced
/// with it. Alarm fatigue is the failure mode being prevented here.
///
/// ### What it does instead
///
/// Per vital, a notification fires only when all of these hold:
///
/// * the finding has been **continuously present for [sustainFor]** — one noisy
///   sample is not an episode, and at 2 Hz the default covers ~20 packets;
/// * and either it has not been notified before, or the severity has
///   **escalated**, or [repeatAfter] has elapsed since the last one.
///
/// An escalation bypasses the cooldown: warning → critical is new information and
/// must not wait out a ten-minute timer. De-escalation does not re-notify.
///
/// ### What it deliberately does not gate
///
/// The on-screen banner and the alerts popup still reflect the live flag list with
/// no delay and no cooldown. They are idempotent — a finding that stays present
/// keeps one banner on screen rather than producing a second — and holding a
/// critical reading off the screen for ten seconds to avoid a flicker would be
/// trading the wrong thing away. Only the interrupting channel is rate-limited.
library;

import 'package:flutter/foundation.dart';

import '../models/vitals.dart';

@immutable
class _Episode {
  const _Episode({
    required this.since,
    required this.severity,
    this.notifiedAt,
    this.notifiedSeverity,
  });

  /// When this vital's finding first appeared, for [AlertGate.sustainFor].
  final DateTime since;

  final Severity severity;
  final DateTime? notifiedAt;
  final Severity? notifiedSeverity;

  _Episode copyWith({
    Severity? severity,
    DateTime? notifiedAt,
    Severity? notifiedSeverity,
  }) =>
      _Episode(
        since: since,
        severity: severity ?? this.severity,
        notifiedAt: notifiedAt ?? this.notifiedAt,
        notifiedSeverity: notifiedSeverity ?? this.notifiedSeverity,
      );
}

class AlertGate {
  AlertGate({
    this.sustainFor = const Duration(seconds: 10),
    this.repeatAfter = const Duration(minutes: 10),
  });

  /// How long a finding must persist before it is worth interrupting for.
  ///
  /// Ten seconds. Long enough that a single motion artefact or a loose strap does
  /// not raise an alarm, short enough that a real desaturation is not sat on — the
  /// on-screen banner is already showing it during this window, so nothing is
  /// hidden, only the notification is withheld.
  final Duration sustainFor;

  /// How long before the same unchanged finding may interrupt again.
  ///
  /// A reminder, not a repeat: the point is that the episode is still going, which
  /// the user may need telling once in a while if they put the phone down.
  final Duration repeatAfter;

  final Map<String, _Episode> _episodes = <String, _Episode>{};

  /// Findings that should be notified now.
  ///
  /// Call on every reading with the complete current flag list — a vital absent
  /// from [flags] has resolved, and its episode is forgotten so a later
  /// recurrence is treated as new rather than inheriting an old cooldown.
  ///
  /// Info-level findings never notify. They are not alarms, and a max-importance
  /// interruption for "body temperature is slightly below normal" is exactly the
  /// noise that makes the critical ones ignorable. They still appear in the popup.
  List<AcuteFlag> due(List<AcuteFlag> flags, {DateTime? now}) {
    final at = now ?? DateTime.now();

    final present = <String>{for (final f in flags) f.vital};
    _episodes.removeWhere((vital, _) => !present.contains(vital));

    final result = <AcuteFlag>[];

    for (final flag in flags) {
      if (flag.severity == Severity.info) continue;

      final existing = _episodes[flag.vital];

      if (existing == null) {
        // First sighting. Starts the sustain clock; notifies nothing yet.
        _episodes[flag.vital] = _Episode(since: at, severity: flag.severity);
        continue;
      }

      var episode = existing.copyWith(severity: flag.severity);

      if (at.difference(episode.since) < sustainFor) {
        _episodes[flag.vital] = episode;
        continue;
      }

      final escalated = episode.notifiedSeverity != null &&
          _rank(flag.severity) > _rank(episode.notifiedSeverity!);
      final cooledDown = episode.notifiedAt == null ||
          at.difference(episode.notifiedAt!) >= repeatAfter;

      if (escalated || cooledDown) {
        result.add(flag);
        episode = _Episode(
          since: episode.since,
          severity: flag.severity,
          notifiedAt: at,
          notifiedSeverity: flag.severity,
        );
      }

      _episodes[flag.vital] = episode;
    }

    return result;
  }

  /// Forgets everything. For a link drop: the readings that follow a reconnect
  /// describe a fresh situation, and a stale cooldown would suppress the first
  /// alarm after it.
  void reset() => _episodes.clear();

  static int _rank(Severity s) => switch (s) {
        Severity.critical => 2,
        Severity.warning => 1,
        Severity.info => 0,
      };
}
