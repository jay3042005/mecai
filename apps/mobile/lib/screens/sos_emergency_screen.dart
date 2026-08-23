/// Fullscreen Emergency SOS.
///
/// Triggered by the SOS button on the watch (over BLE) or from the app. Runs a
/// five-second grace countdown — during which a GPS fix is acquired and the
/// alert is written to the local archive — then hands the composed emergency
/// message to the platform SMS app and opens the dialler on the configured
/// emergency number. Cancelling inside the grace period sends nothing and syncs
/// the cancellation back to the watch.
///
/// The emergency number is configuration, not a literal: the right line to call
/// is a local fact, set per deployment in Settings.
///
/// ### Motion, and the one exception
///
/// This is the single screen where urgency motion is correct (docs/design.md §7),
/// so the siren throb stays. But it now **stops under reduced motion**, which it
/// did not before: §3.6 names a pulsing red full-screen alert as a vestibular
/// hazard and "exactly the wrong thing to show someone who may be having a
/// cardiac event". Under that setting the hero is a steady lit circle.
///
/// The **haptic siren keeps running regardless**. Reduced motion is a request
/// about visual movement, not a request to be told less loudly that an ambulance
/// is being called — silencing the alert channel would be the wrong reading of it.
///
/// ### Colour
///
/// Every value here is a token. The version this replaces hardcoded `0xFF140808`,
/// `0xFF2C1515`, `Colors.redAccent` and `Colors.greenAccent`; the surfaces below
/// are now the alarm red blended over the page and card at [MecState] opacities,
/// so they track the palette instead of drifting from it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/location_service.dart';
import '../data/monitor_controller.dart';
import '../data/sos_dispatcher.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import '../widgets/mec_press.dart';
import '../widgets/sos_telemetry.dart';
import 'emergency_contacts_screen.dart';

class SosEmergencyScreen extends StatefulWidget {
  const SosEmergencyScreen({
    super.key,
    required this.latestReading,
    required this.onCancelSos,
    required this.controller,
  });

  final VitalsReading? latestReading;
  final VoidCallback onCancelSos;

  /// Supplies the location fix, the contact list, and the message hand-off.
  final MonitorController controller;

  @override
  State<SosEmergencyScreen> createState() => _SosEmergencyScreenState();
}

/// What the alert is doing right now.
///
/// There is no "calling" or "connected" state any more. The screen used to run a
/// scripted dial-then-connect sequence with a call timer, which showed
/// "911 Emergency Dispatch" and a ticking duration while nothing was happening —
/// an emergency screen asserting an open line to a dispatcher it had never
/// contacted. Every state below is a real one.
enum _SosPhase {
  /// Grace period. Cancelling here sends nothing.
  countdown,

  /// Acquiring a fix and handing the message to the radio.
  sending,

  /// The radio accepted it.
  sent,

  /// It did not go out. The reason is shown, because it is actionable.
  failed;

  String get title => switch (this) {
        _SosPhase.countdown => '',
        _SosPhase.sending => 'Sending emergency SMS…',
        _SosPhase.sent => 'Alert sent',
        _SosPhase.failed => 'Could not send the SMS',
      };
}

class _SosEmergencyScreenState extends State<SosEmergencyScreen>
    with TickerProviderStateMixin {
  _SosPhase _phase = _SosPhase.countdown;
  int _countdown = 5;

  LocationFix? _fix;
  DispatchResult? _dispatch;
  bool _locating = true;

  Timer? _countdownTimer;
  Timer? _hapticTimer;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: MecMotion.ambient,
  );

  @override
  void initState() {
    super.initState();
    _startHapticSiren();
    _startCountdown();
    // Starts immediately, in parallel with the countdown. A GPS fix takes seconds,
    // and the five-second grace period is exactly the window to spend acquiring
    // one — so by the time the message is composed the location is usually there.
    _locationAttempt = _acquireLocation();
  }

  /// Held so [_send] can wait for the fix rather than racing it.
  late final Future<void> _locationAttempt;

  Future<void> _acquireLocation() async {
    // The route is the sole SOS recorder. Both app and watch triggers enter here,
    // so recording at either trigger site created duplicate dispatch incidents.
    final fix = await widget.controller.recordSos(widget.controller.sosOrigin);
    if (!mounted) return;
    setState(() {
      _fix = fix;
      _locating = false;
    });
  }


  bool _pulseSynced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pulseSynced) return;
    _pulseSynced = true;

    if (context.reduceMotion) {
      // Steady and fully lit, rather than mid-fade.
      _pulse.value = 1;
    } else {
      _pulse.repeat(reverse: true);
    }
  }

  /// A double-tap cadence, imitating an emergency alarm.
  ///
  /// Deliberately *not* gated on reduced motion — see the library comment.
  void _startHapticSiren() {
    _hapticTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      HapticFeedback.heavyImpact();
    });
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        if (_countdown > 1) {
          _countdown--;
        } else {
          timer.cancel();
          _send();
        }
      });
    });
  }

  /// Grace period elapsed without a cancel, so the alert goes out.
  ///
  /// Does not wait on delivery. The send is fired and the screen moves to [sent]
  /// as soon as the message is on its way: a delivery report can take tens of
  /// seconds or never arrive on a weak signal, and holding the screen on
  /// "Sending…" for that tells someone in an emergency that nothing has happened
  /// yet when it has. If the radio later reports a real problem the status is
  /// corrected, so nothing is claimed that cannot be withdrawn.
  Future<void> _send() async {
    setState(() => _phase = _SosPhase.sending);

    // Waits for the location attempt if it is still running, so the message
    // carries a fix whenever one is obtainable — the fix attempt is already
    // bounded by LocationService, so this cannot hang.
    await _locationAttempt;
    if (!mounted) return;

    setState(() => _phase = _SosPhase.sent);

    unawaited(
      widget.controller.dispatchSms().then((result) {
        if (!mounted) return;
        setState(() => _dispatch = result);
        // No "failed" phase on SMS trouble alone: the alert itself was
        // recorded with its location and uploaded the moment the countdown
        // ended, so responders on the dashboard already see it. Reporting
        // that as failure would tell someone in an emergency that nothing
        // happened when the part that matters did.
      }),
    );
  }

  /// Skips the remaining grace period and sends now.
  void _sendNow() {
    _countdownTimer?.cancel();
    unawaited(_send());
  }

  /// Closes the screen, then stands the alert down.
  ///
  /// The order matters and is load-bearing. [AppShell] also listens for SOS
  /// going inactive, because a cancel pressed on the *watch* has to close this
  /// screen too. If the controller were notified first, that listener would
  /// remove this route and the pop below would then take the shell's own route
  /// with it — an empty navigator, which paints as a black screen. Popping
  /// first leaves the shell nothing to remove, and it checks before removing.
  void _cancel() {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
    widget.onCancelSos();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _hapticTimer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    // The alarm red, laid over the page and card surfaces. Derived rather than
    // hardcoded, so it follows the palette.
    final page = Color.alphaBlend(
      MecAlarm.color.withValues(alpha: MecState.hover),
      c.page,
    );
    final nested = Color.alphaBlend(
      MecAlarm.color.withValues(alpha: MecState.hover),
      c.card,
    );

    return PopScope(
      // No accidental back-swipe out of an active emergency.
      canPop: false,
      child: Scaffold(
        backgroundColor: page,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MecSpace.s20,
              vertical: MecSpace.s12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: _banner(c)),
                const Spacer(),
                Center(child: _hero()),
                const SizedBox(height: MecSpace.s12),
                ..._status(c),
                const Spacer(),
                SosTelemetryCard(
                  reading: widget.latestReading,
                  surface: nested,
                  fix: _fix,
                  locating: _locating,
                ),
                const SizedBox(height: MecSpace.s8),
                _contactsNote(c, nested),
                const Spacer(),
                _cancelButton(c, nested),
                const SizedBox(height: MecSpace.s8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _banner(MecColors c) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MecSpace.s16,
          vertical: MecSpace.s6,
        ),
        decoration: BoxDecoration(
          color: MecAlarm.color.withValues(alpha: MecState.press),
          borderRadius: BorderRadius.circular(MecRadius.chip),
          border: Border.all(color: MecAlarm.color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: _pulse,
              child: const Icon(
                Icons.warning_rounded,
                size: 16,
                color: MecAlarm.color,
              ),
            ),
            const SizedBox(width: MecSpace.s8),
            Text(
              'EMERGENCY SOS ACTIVE',
              style: MecType.label.copyWith(
                color: c.inkPrimary,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      );

  /// The siren. A lit core inside a ring that breathes — or, under reduced
  /// motion, simply a lit core.
  Widget _hero() => AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final scale = 1.0 + _pulse.value * 0.14;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 104 * scale,
                height: 104 * scale,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: MecAlarm.color.withValues(
                    alpha: 0.22 * (1.0 - _pulse.value),
                  ),
                ),
              ),
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: MecAlarm.color,
                  boxShadow: MecElevation.raised,
                ),
                child: Icon(
                  // The glyph tracks the phase, so the hero is a status channel
                  // and not only decoration.
                  switch (_phase) {
                    _SosPhase.sent => Icons.mark_email_read_rounded,
                    _SosPhase.failed => Icons.sms_failed_rounded,
                    _ => Icons.sos_rounded,
                  },
                  size: 42,
                  // White on the alarm red measures 4.80.
                  color: MecSurfaceDark.inkPrimary,
                ),
              ),
            ],
          );
        },
      );

  List<Widget> _status(MecColors c) {
    final headline = MecType.heroFigure.copyWith(
      color: c.inkPrimary,
      fontSize: 24,
    );
    final sub = MecType.body.copyWith(color: c.inkSecondary, fontSize: 13);

    return switch (_phase) {
      _SosPhase.countdown => [
          Text(
            'Sending in $_countdown…',
            textAlign: TextAlign.center,
            style: headline,
          ),
          const SizedBox(height: MecSpace.s4),
          Text(
            'SOS triggered from your MEC-AI watch. Keep calm.',
            textAlign: TextAlign.center,
            style: sub,
          ),
          const SizedBox(height: MecSpace.s4),
          Center(
            child: MecPress(
              child: TextButton.icon(
                onPressed: _sendNow,
                icon: const Icon(Icons.send_rounded, size: 16),
                label: const Text('Send now'),
              ),
            ),
          ),
        ],
      _SosPhase.sending => [
          Text(_phase.title, textAlign: TextAlign.center, style: headline),
          const SizedBox(height: MecSpace.s4),
          Text(
            _locating
                ? 'Getting your location…'
                : 'Handing the message to your phone’s radio…',
            textAlign: TextAlign.center,
            style: sub,
          ),
        ],
      _SosPhase.sent => [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, size: 20, color: MecRiskBand.low.color),
              const SizedBox(width: MecSpace.s8),
              Flexible(
                child: Text(
                  _phase.title,
                  textAlign: TextAlign.center,
                  style: headline.copyWith(fontSize: 22),
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s4),
          // Lead with the part that always happened: the alert and its
          // location reached the dashboard at the end of the countdown. SMS is
          // a second, best-effort channel on top of that.
          Text(
            'Recorded with your location — visible to responders on the '
            'dashboard now.',
            textAlign: TextAlign.center,
            style: sub,
          ),
          if (_dispatch?.sentTo.isNotEmpty ?? false) ...[
            const SizedBox(height: MecSpace.s4),
            Text(
              'SMS sent to ${_dispatch!.sentTo.join(', ')}',
              textAlign: TextAlign.center,
              style: sub,
            ),
          ],
          if (_dispatch?.failedFor.isNotEmpty ?? false) ...[
            const SizedBox(height: MecSpace.s4),
            Text(
              'SMS could not reach ${_dispatch!.failedFor.join(', ')} — '
              'check signal or SIM credit. Responders still see this alert.',
              textAlign: TextAlign.center,
              style: MecType.label.copyWith(color: MecRiskBand.moderate.color),
            ),
          ] else if (_dispatch != null &&
              _dispatch!.outcome == DispatchOutcome.failed) ...[
            const SizedBox(height: MecSpace.s4),
            Text(
              'No SMS went out — check that a SIM is active. Your alert and '
              'location are already on the dashboard.',
              textAlign: TextAlign.center,
              style: MecType.label.copyWith(color: MecRiskBand.moderate.color),
            ),
          ],
        ],
      _SosPhase.failed => [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 20,
                color: MecRiskBand.high.color,
              ),
              const SizedBox(width: MecSpace.s8),
              Flexible(
                child: Text(
                  _phase.title,
                  textAlign: TextAlign.center,
                  style: headline.copyWith(fontSize: 22),
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s4),
          Text(
            _dispatch?.outcome.label ?? 'The message could not be sent.',
            textAlign: TextAlign.center,
            style: sub,
          ),
          const SizedBox(height: MecSpace.s8),
          Center(
            child: MecPress(
              child: TextButton.icon(
                onPressed: _sendNow,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Try again'),
              ),
            ),
          ),
        ],
    };
  }

  /// Location and delivery status.
  ///
  /// This replaced a line that stated "SMS alert with live vitals & map sent to
  /// emergency contacts" unconditionally — while nothing was sent and no location
  /// was read. On an emergency screen a false claim of delivery is the worst kind
  /// of copy: it tells someone help is coming when it is not. Every line here now
  /// reports something that actually happened.
  Widget _contactsNote(MecColors c, Color surface) {
    final contacts = widget.controller.emergencyContacts.contacts;
    final fix = _fix;
    final result = _dispatch;

    final (icon, text) = switch ((result?.outcome, _locating, fix)) {
      (DispatchOutcome.noContacts, _, _) => (
          Icons.person_off_outlined,
          'No emergency contact set. Add one in Profile → Emergency contacts.',
        ),
      (DispatchOutcome.permissionDenied, _, _) => (
          Icons.sms_failed_outlined,
          'This app needs permission to send SMS. Grant it in '
              'Profile → Emergency contacts.',
        ),
      (DispatchOutcome.unsupported, _, _) => (
          Icons.phonelink_erase_outlined,
          'This phone cannot send SMS automatically. The emergency and your '
              'location were still recorded and uploaded.',
        ),
      (_, true, _) => (Icons.location_searching, 'Getting your location…'),
      (_, _, final f) when f != null && f.hasPosition => (
          Icons.my_location,
          '${f.quality.label}: ${f.coordinatesLabel}'
              '${contacts.isEmpty ? ' · no contact set' : ' · a map link was included'}',
        ),
      (_, _, final f) => (
          Icons.location_disabled,
          f?.problem ?? 'Location unavailable.',
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MecSpace.s12,
        vertical: MecSpace.s8,
      ),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(MecRadius.card),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: c.series1),
          const SizedBox(width: MecSpace.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: MecType.axisTick.copyWith(color: c.inkMuted, fontSize: 11),
                ),
                if (contacts.isEmpty) ...[
                  const SizedBox(height: MecSpace.s4),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => EmergencyContactsScreen(
                          contacts: widget.controller.emergencyContacts,
                          locationService: widget.controller.locationService,
                          dispatcher: const SosDispatcher(),
                        ),
                      ),
                    ),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    child: const Text('Set up emergency contact'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cancelButton(MecColors c, Color surface) => MecPress(
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: surface,
            foregroundColor: c.inkPrimary,
            shape: const StadiumBorder(
              side: BorderSide(color: MecAlarm.color, width: 1.5),
            ),
            padding: const EdgeInsets.symmetric(vertical: MecSpace.s16),
          ).copyWith(overlayColor: mecStateLayer(MecAlarm.color)),
          onPressed: _cancel,
          icon: const Icon(Icons.close_rounded, size: 18),
          label: Text(
            _phase == _SosPhase.countdown
                ? 'Cancel SOS (false alarm)'
                : 'Dismiss',
            style: MecType.body.copyWith(
              color: c.inkPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
      );
}
