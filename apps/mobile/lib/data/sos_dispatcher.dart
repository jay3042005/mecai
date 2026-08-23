/// Sends the emergency SMS.
///
/// Direct send, no composer: the message goes out the moment the grace period
/// ends, using Android's `SEND_SMS` permission. That is the point of the feature —
/// the watch button is pressed by someone who may be unable to confirm a dialog,
/// and an alert waiting on a tap is an alert that may never leave.
///
/// The message is sent from the user's own number, so the contact sees who it is
/// from and can reply or call back.
///
/// ### It will not appear in the phone's Messages app
///
/// `SmsManager.sendTextMessage` transmits through the telephony stack but cannot
/// write to the SMS content provider — since Android 4.4 only the *default SMS
/// app* may do that. So a perfectly successful emergency SMS leaves no trace in
/// Messages, and its absence there is not evidence of failure. That is why
/// [sendEmergencySms] takes an `onStatus` callback: the carrier's SENT/DELIVERED
/// report is the only real confirmation available.
///
/// **Android only.** iOS exposes no API for programmatic SMS, so [isSupported]
/// gates the attempt rather than letting it fail at runtime — and the SOS still
/// records the emergency and its location either way.
library;

import 'dart:io' show Platform;

import 'package:another_telephony/telephony.dart';
import 'package:flutter/foundation.dart';

import 'emergency_contacts.dart';
import 'location_service.dart';

enum DispatchOutcome {
  /// Handed to the radio for every recipient.
  sent,

  /// Sent to some recipients but not all.
  partial,

  /// No contacts are configured, so there is nobody to send to.
  noContacts,

  /// The user has not granted permission to send SMS.
  permissionDenied,

  /// This platform cannot send an SMS programmatically.
  unsupported,

  /// The radio rejected the message.
  failed;

  String get label => switch (this) {
        DispatchOutcome.sent => 'Emergency SMS sent',
        DispatchOutcome.partial => 'Some messages could not be sent',
        DispatchOutcome.noContacts => 'No emergency contact set',
        DispatchOutcome.permissionDenied => 'SMS permission not granted',
        DispatchOutcome.unsupported => 'This phone cannot send SMS automatically',
        DispatchOutcome.failed => 'The message could not be sent',
      };

  bool get delivered =>
      this == DispatchOutcome.sent || this == DispatchOutcome.partial;
}

@immutable
class DispatchResult {
  const DispatchResult({
    required this.outcome,
    this.sentTo = const [],
    this.failedFor = const [],
    this.message = '',
  });

  final DispatchOutcome outcome;
  final List<String> sentTo;
  final List<String> failedFor;

  /// The text that was sent, so the screen can show exactly what the contact got
  /// rather than a paraphrase of it.
  final String message;
}

class SosDispatcher {
  const SosDispatcher();

  /// Whether this platform can send an SMS without user interaction.
  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } on Object {
      return false;
    }
  }

  /// The SMS body.
  ///
  /// Ordered by what a reader needs first: that it is an emergency, who it is
  /// from, then where, then the vitals. A responder skimming a notification
  /// preview sees the first line, so the first line is the emergency itself and
  /// never a greeting.
  ///
  /// The map link is on its own line so messaging apps linkify it cleanly —
  /// trailing punctuation gets swallowed into the URL by some clients, which
  /// breaks the one part of the message that has to work.
  /// Characters outside the GSM 03.38 alphabet, mapped to plain ASCII.
  ///
  /// This matters more than it looks. A single non-GSM-7 character forces the whole
  /// message into UCS-2, where the per-part limit drops from 160 characters to
  /// **70** — so one em-dash turned a two-part message into a five-part one. Every
  /// extra part is another segment the carrier can drop, and another segment the
  /// user pays for.
  static const _gsmReplacements = <String, String>{
    '\u2014': '-', // em dash
    '\u2013': '-', // en dash
    '\u2018': "'", // left single quote
    '\u2019': "'", // right single quote
    '\u201C': '"', // left double quote
    '\u201D': '"', // right double quote
    '\u2026': '...', // ellipsis
    '\u00B0': ' deg', // degree sign
    '\u2022': '-', // bullet
    '\u00A0': ' ', // non-breaking space
  };

  /// Forces [text] into the GSM-7 alphabet so it sends as 160-character parts.
  static String toGsm7(String text) {
    var result = text;
    _gsmReplacements.forEach((from, to) => result = result.replaceAll(from, to));
    return result;
  }

  static String composeMessage({
    required String patientName,
    required LocationFix fix,
    double? heartRateBpm,
    double? spo2Pct,
    DateTime? at,
  }) {
    final when = (at ?? DateTime.now()).toLocal();
    final clock = '${when.hour.toString().padLeft(2, '0')}:'
        '${when.minute.toString().padLeft(2, '0')}';

    final lines = <String>[
      'EMERGENCY - I need help.',
      'This is an automatic alert from $patientName\'s MEC-AI watch, sent at $clock.',
    ];

    final vitals = <String>[
      if (heartRateBpm != null) 'heart rate ${heartRateBpm.round()} bpm',
      if (spo2Pct != null) 'blood oxygen ${spo2Pct.round()}%',
    ];
    if (vitals.isNotEmpty) {
      lines.add('Last reading: ${vitals.join(', ')}.');
    }

    if (fix.hasPosition) {
      lines
        ..add(
          fix.quality == FixQuality.live
              ? 'My location:'
              : 'My last known location:',
        )
        ..add(fix.mapsUrl!)
        ..add('(${fix.coordinatesLabel})');
    } else {
      // Says so explicitly. Silence about location reads as "no location was
      // needed" rather than "location could not be obtained".
      lines.add('Location unavailable - please call me.');
    }

    lines.add('Please call me or send help.');
    // Sanitised at the boundary rather than by hand in each string, so a future
    // edit that types a curly apostrophe cannot quietly double the part count.
    return toGsm7(lines.join('\n'));
  }

  /// Requests SMS permission.
  ///
  /// Called from the contacts screen so the prompt appears while the user is
  /// calmly setting the feature up. Asking for the first time mid-emergency would
  /// put a permission dialog between someone and their alert.
  Future<bool> ensurePermission() async {
    if (!isSupported) return false;
    try {
      return await Telephony.instance.requestSmsPermissions ?? false;
    } on Object catch (error) {
      debugPrint('SosDispatcher: permission request failed. $error');
      return false;
    }
  }

  /// Sends the emergency message to every configured contact.
  ///
  /// Each recipient is a separate send rather than one multi-recipient message: a
  /// number the carrier rejects then costs only its own delivery, instead of
  /// taking the whole alert down with it. [DispatchResult.failedFor] names the ones
  /// that did not go, so the screen can say which rather than reporting a vague
  /// partial failure.
  Future<DispatchResult> sendEmergencySms({
    required List<EmergencyContact> contacts,
    required String message,
    void Function(String contactName, SendStatus status)? onStatus,
  }) async {
    if (contacts.isEmpty) {
      return const DispatchResult(outcome: DispatchOutcome.noContacts);
    }
    if (!isSupported) {
      return DispatchResult(
        outcome: DispatchOutcome.unsupported,
        message: message,
      );
    }

    final telephony = Telephony.instance;

    // Checked, not assumed: without the grant every send throws, and reporting
    // "permission denied" is actionable where "could not send" is not.
    final granted = await telephony.requestSmsPermissions ?? false;
    if (!granted) {
      return DispatchResult(
        outcome: DispatchOutcome.permissionDenied,
        message: message,
      );
    }

    final sentTo = <String>[];
    final failedFor = <String>[];

    for (final contact in contacts) {
      final number = EmergencyContacts.normalizePhone(contact.phone);
      if (number.isEmpty) {
        failedFor.add(contact.name);
        continue;
      }
      try {
        await telephony.sendSms(
          to: number,
          message: message,
          // Essential, not an optimisation. The emergency text runs to ~280
          // characters, and a single-part send silently fails or truncates past
          // 160. Without this the alert appeared to send and never arrived.
          isMultipart: true,
          // Reported asynchronously: the screen must not block on a delivery
          // report, which can take many seconds or never arrive on a weak signal.
          // The callback upgrades the status when it does come.
          statusListener: onStatus == null
              ? null
              : (status) => onStatus(contact.name, status),
        );
        sentTo.add(contact.name);
      } on Object catch (error) {
        debugPrint('SosDispatcher: send to ${contact.name} failed. $error');
        failedFor.add(contact.name);
      }
    }

    return DispatchResult(
      outcome: sentTo.isEmpty
          ? DispatchOutcome.failed
          : failedFor.isEmpty
              ? DispatchOutcome.sent
              : DispatchOutcome.partial,
      sentTo: sentTo,
      failedFor: failedFor,
      message: message,
    );
  }
}
