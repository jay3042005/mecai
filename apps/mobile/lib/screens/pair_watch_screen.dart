/// First-run MEC-AI watch connection flow.
///
/// Walks the user from permissions through scan, discovery, connection and
/// handshake, showing where they are at every step. The state machine is
/// unchanged from the version that shipped; what changed is the layout and the
/// hero.
///
/// ### Fitting on the screen
///
/// The previous version was a `ListView`: wordmark, a 220dp hero, title,
/// subtitle, four stacked guide cards and the button, roughly 900dp of content.
/// On any phone it scrolled, which put the first thing to read and the last thing
/// to tap in different viewports and left the button below the fold on arrival.
///
/// This version measures instead. Everything below the hero has a known height,
/// so the hero takes what is left ([_HeroFit]) and the whole flow lands in one
/// viewport from a 640dp phone upward. The guide is one page at a time with
/// tappable dots rather than a stack — a fixed height, and room for the hero to
/// illustrate each step. Below the floor where the hero would stop being legible
/// the screen falls back to scrolling rather than overflowing.
///
/// ### The hero
///
/// [PairHero] draws the actual prototype ([MecWatchDevice]) with the firmware's
/// own panel content behind the glass, inside the boot animation's concentric
/// rings run as a radar. The panel follows the flow: the boot wordmark while the
/// guide says "power on", `BLE:OK` while it says "turn on Bluetooth", range arcs
/// while it says "keep it close", the sweep while the phone scans. So arriving
/// here reads as a continuation of the splash, and the guide shows the user the
/// object and the screen it is describing.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/settings.dart';
import '../data/vitals_source.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../widgets/mec_boot_fx.dart';
import '../widgets/mec_press.dart';
import '../widgets/mec_watch_face.dart';
import '../widgets/pair_hero.dart';
import '../widgets/pair_steps.dart';

class PairWatchScreen extends StatefulWidget {
  const PairWatchScreen({
    super.key,
    required this.source,
    required this.settings,
    required this.onConnected,
    this.onSkip,
  });

  final VitalsSource source;
  final AppSettings settings;
  final VoidCallback onConnected;

  /// Called when the user long-holds the action button to continue without a
  /// watch.
  ///
  /// Deliberately invisible until used: there is no "Skip" button anywhere.
  /// Someone who has no watch yet — or whose watch is across the room — holds
  /// [the primary button] for three seconds and lands in the app, where
  /// monitoring works fine and pairing remains available in Settings. A visible
  /// skip would read as the recommended path; this keeps pairing first without
  /// making it mandatory.
  final VoidCallback? onSkip;

  @override
  State<PairWatchScreen> createState() => _PairWatchScreenState();
}

/// Each step the user sees in the connection guide.
enum _SetupStep {
  welcome,
  permissions,
  scanning,
  found,
  connecting,
  handshake,
  connected,
  error;

  /// Human label shown on the button while the flow runs.
  String get label => switch (this) {
        _SetupStep.welcome => '',
        _SetupStep.permissions => 'Requesting permissions…',
        _SetupStep.scanning => 'Scanning for MECAI-Watch…',
        _SetupStep.found => 'Found MECAI-Watch!',
        _SetupStep.connecting => 'Connecting…',
        _SetupStep.handshake => 'Setting up live data…',
        _SetupStep.connected => 'Connected!',
        _SetupStep.error => 'Connection failed',
      };

  /// Progress fraction for the top bar (0.0–1.0).
  double get progress => switch (this) {
        _SetupStep.welcome => 0.0,
        _SetupStep.permissions => 0.10,
        _SetupStep.scanning => 0.30,
        _SetupStep.found => 0.50,
        _SetupStep.connecting => 0.65,
        _SetupStep.handshake => 0.85,
        _SetupStep.connected => 1.0,
        _SetupStep.error => 0.0,
      };

  bool get isActive => this != _SetupStep.welcome && this != _SetupStep.error;

  /// What the rings draw. Coarser than the step itself.
  PairHeroPhase get heroPhase => switch (this) {
        _SetupStep.welcome => PairHeroPhase.idle,
        _SetupStep.permissions => PairHeroPhase.searching,
        _SetupStep.scanning => PairHeroPhase.searching,
        _SetupStep.found => PairHeroPhase.closing,
        _SetupStep.connecting => PairHeroPhase.closing,
        _SetupStep.handshake => PairHeroPhase.closing,
        _SetupStep.connected => PairHeroPhase.success,
        _SetupStep.error => PairHeroPhase.error,
      };

  /// What the watch's own panel shows. Null on [welcome] and [error], where the
  /// guide page the user is reading decides instead.
  MecWatchFaceMode? get face => switch (this) {
        _SetupStep.permissions => MecWatchFaceMode.advertising,
        _SetupStep.scanning => MecWatchFaceMode.scanning,
        _SetupStep.found => MecWatchFaceMode.linking,
        _SetupStep.connecting => MecWatchFaceMode.linking,
        _SetupStep.handshake => MecWatchFaceMode.linking,
        _SetupStep.connected => MecWatchFaceMode.linked,
        _SetupStep.error => MecWatchFaceMode.offline,
        _SetupStep.welcome => null,
      };

  /// How far the radar's colour has drained toward the data hue — the screen's
  /// way of showing growing certainty without a word.
  double get settle => switch (this) {
        _SetupStep.found => 0.45,
        _SetupStep.connecting => 0.75,
        _SetupStep.handshake => 1.0,
        _ => 0.0,
      };
}

/// The heights everything below the hero occupies, so the hero can be given what
/// is left instead of a guess.
///
/// Kept as one block of numbers because they are a budget: if a row grows, the
/// hero shrinks, and both facts should be visible in the same place.
abstract final class _Fit {
  static const double header = 30;
  static const double title = 72;
  static const double guide = 126;
  static const double dots = MecChart.minHitTarget;
  static const double action = 50;
  static const double success = 74;

  static const double gapAfterHero = MecSpace.s12;
  static const double gapAfterTitle = MecSpace.s16;
  static const double gapBeforeDots = MecSpace.s4;
  static const double gapBeforeAction = MecSpace.s8;

  /// Below this the panel's text stops being legible, so scrolling is the honest
  /// answer rather than a watch the size of a thumbnail.
  static const double minHero = 148;
}

class _PairWatchScreenState extends State<PairWatchScreen>
    with TickerProviderStateMixin {
  _SetupStep _step = _SetupStep.welcome;
  String? _error;

  /// Which guide page is showing. Drives the hero's panel.
  int _page = 0;
  final PageController _pages = PageController();

  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: MecMotion.value,
  );

  /// Letter-pops the wordmark on arrival, the same gesture the splash makes.
  late final AnimationController _wordmark = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  );

  static const String _word = 'MEC-AI';

  bool _introDone = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_introDone) return;
    _introDone = true;
    if (context.reduceMotion) {
      _wordmark.value = 1;
    } else {
      _wordmark.forward();
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    _progress.dispose();
    _wordmark.dispose();
    super.dispose();
  }

  void _setStep(_SetupStep step) {
    if (!mounted) return;
    setState(() => _step = step);
    if (context.reduceMotion) {
      _progress.value = step.progress;
    } else {
      _progress.animateTo(step.progress, curve: MecEasing.standard);
    }
  }

  Future<bool> _requestPermissions() async {
    if (kIsWeb) return true;

    if (Platform.isAndroid) {
      try {
        await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetooth,
          Permission.location,
        ].request();
      } catch (e) {
        debugPrint('BLE permission request notice: $e');
      }
    }

    try {
      final adapterState = await FlutterBluePlus.adapterState.first.timeout(
        const Duration(milliseconds: 1500),
        onTimeout: () => BluetoothAdapterState.on,
      );
      if (adapterState == BluetoothAdapterState.off) {
        _showError(
          'Bluetooth is turned off.\n\nPlease turn ON Bluetooth in your phone '
          'settings, then tap Try Again.',
        );
        return false;
      }
    } catch (_) {}

    return true;
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _step = _SetupStep.error;
      // The diagnostic becomes page 0 of the guide, so the fix is the first thing
      // in the viewport and the steps stay one swipe away.
      _page = 0;
    });
    if (_pages.hasClients) _pages.jumpToPage(0);
    _progress.animateTo(0, curve: MecEasing.accelerate);
  }

  Future<void> _startConnection() async {
    setState(() => _error = null);

    _setStep(_SetupStep.permissions);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final permitted = await _requestPermissions();
    if (!permitted) return;

    _setStep(_SetupStep.scanning);

    try {
      // BleVitalsSource.connect() does scan + connect + service discovery in one
      // call; the stages below are the user-visible breakdown of it.
      await widget.source.connect();
      if (!mounted) return;

      if (widget.source.currentLinkState != LinkState.connected &&
          widget.source.currentLinkState != LinkState.streaming) {
        _showError(
          'Could not find MECAI-Watch nearby.\n\n'
          'Please check:\n'
          '• The watch is powered on\n'
          '• The watch is within 1 metre of this phone\n'
          '• Bluetooth is enabled on this phone\n'
          '• No other phone is already connected',
        );
        return;
      }

      _setStep(_SetupStep.found);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      _setStep(_SetupStep.connecting);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _setStep(_SetupStep.handshake);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      _setStep(_SetupStep.connected);
      await widget.settings.setWatchPaired(true);

      // Long enough for the sparkle pass to land before the screen changes.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted) widget.onConnected();
    } catch (e) {
      _showError(
        'Could not find or connect to MECAI-Watch.\n\n'
        'Please check:\n'
        '• The watch is powered on\n'
        '• The watch is within 1 metre of this phone\n'
        '• Bluetooth is enabled on this phone\n\n'
        'Error: $e',
      );
    }
  }

  // ── layout ──────────────────────────────────────────────────────────────

  bool get _showsGuide =>
      _step == _SetupStep.welcome || _step == _SetupStep.error;

  /// Guide pages: the four steps, with the diagnostic prepended on a failure.
  int get _pageCount => pairGuideSteps.length + (_step == _SetupStep.error ? 1 : 0);

  /// The guide step the current page is showing, or null on the error page.
  PairGuideStep? get _visibleStep {
    if (!_showsGuide) return null;
    final offset = _step == _SetupStep.error ? 1 : 0;
    final i = _page - offset;
    return i >= 0 && i < pairGuideSteps.length ? pairGuideSteps[i] : null;
  }

  /// What the watch's panel shows: the connection stage once running, otherwise
  /// whatever the guide page the user is reading is illustrating.
  MecWatchFaceMode get _face =>
      _step.face ?? _visibleStep?.face ?? MecWatchFaceMode.asleep;

  /// Height of the block under the title, which is what varies by state.
  double get _bodyHeight => switch (_step) {
        _SetupStep.connected => _Fit.success,
        _SetupStep.welcome ||
        _SetupStep.error =>
          _Fit.guide + _Fit.gapBeforeDots + _Fit.dots,
        _ => PairStatusStep.heightFor(6),
      };

  /// Everything that is not the hero.
  double get _chromeHeight {
    final action = _step == _SetupStep.connected
        ? 0.0
        : _Fit.gapBeforeAction + _Fit.action;
    return _Fit.header +
        _Fit.gapAfterHero +
        _Fit.title +
        _Fit.gapAfterTitle +
        _bodyHeight +
        action;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final isDone = _step == _SetupStep.connected;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            AnimatedBuilder(
              animation: _progress,
              builder: (context, _) => LinearProgressIndicator(
                value: _progress.value,
                minHeight: 3,
                backgroundColor: c.gridline,
                valueColor: AlwaysStoppedAnimation<Color>(
                  isDone ? MecRiskBand.low.color : c.series1,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  MecSpace.s24,
                  MecSpace.s12,
                  MecSpace.s24,
                  MecSpace.s20,
                ),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final hero = math.min(
                      box.maxWidth,
                      (box.maxHeight - _chromeHeight) / PairHero.heightRatio,
                    );

                    return hero < _Fit.minHero
                        ? _scrolling(box.maxWidth)
                        : _fitted(hero);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The measured layout: fixed rows, and the hero absorbing the slack.
  Widget _fitted(double hero) => Column(
        children: <Widget>[
          SizedBox(height: _Fit.header, child: _header()),
          Expanded(child: Center(child: _hero(hero))),
          const SizedBox(height: _Fit.gapAfterHero),
          SizedBox(height: _Fit.title, child: _titleBlock()),
          const SizedBox(height: _Fit.gapAfterTitle),
          SizedBox(height: _bodyHeight, child: _body()),
          if (_step != _SetupStep.connected) ...<Widget>[
            const SizedBox(height: _Fit.gapBeforeAction),
            _action(),
          ],
        ],
      );

  /// The fallback for a viewport too short to hold a legible watch. Same pieces,
  /// same order, allowed to scroll — a nested scrollable is worse than one.
  Widget _scrolling(double width) => SingleChildScrollView(
        child: Column(
          children: <Widget>[
            SizedBox(height: _Fit.header, child: _header()),
            const SizedBox(height: MecSpace.s8),
            Center(child: _hero(math.min(width, _Fit.minHero))),
            const SizedBox(height: _Fit.gapAfterHero),
            _titleBlock(),
            const SizedBox(height: _Fit.gapAfterTitle),
            SizedBox(height: _bodyHeight, child: _body()),
            if (_step != _SetupStep.connected) ...<Widget>[
              const SizedBox(height: _Fit.gapBeforeAction),
              _action(),
            ],
          ],
        ),
      );

  Widget _hero(double size) => PairHero(
        phase: _step.heroPhase,
        face: _face,
        settle: _step.settle,
        size: size,
        highlightButton: _visibleStep?.highlightButton,
      );

  /// The wordmark, popping in letter by letter, flashing to full palette the
  /// moment the watch is actually connected.
  ///
  /// Small: the watch below it carries the silkscreened wordmark at size, so this
  /// is here for continuity with the splash rather than to be read twice.
  Widget _header() => Center(
        child: AnimatedBuilder(
          animation: _wordmark,
          builder: (context, _) => MecWordmark(
            text: _word,
            fontSize: 20,
            visibleLetters: (_wordmark.value * _word.length).ceil(),
            tone: _step == _SetupStep.connected
                ? MecWordmarkTone.palette
                : MecWordmarkTone.settled,
            palette: MecBootPalette.calm,
            paletteOffset: _step == _SetupStep.connected ? 1 : 0,
          ),
        ),
      );

  Widget _titleBlock() {
    final c = context.mec;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedSwitcher(
          duration: context.stilled(MecMotion.fast),
          child: Text(
            _title,
            key: ValueKey(_title),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MecType.sectionTitle.copyWith(
              color: c.inkPrimary,
              fontSize: 20,
              // Pinned: the box below is a fixed height, and the platform
              // fallback font's default line height is taller than Inter's.
              height: 1.25,
            ),
          ),
        ),
        const SizedBox(height: MecSpace.s6),
        AnimatedSwitcher(
          duration: context.stilled(MecMotion.fast),
          child: Text(
            _subtitle,
            key: ValueKey(_subtitle),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: MecType.label.copyWith(color: c.inkSecondary, height: 1.35),
          ),
        ),
      ],
    );
  }

  Widget _body() => switch (_step) {
        _SetupStep.connected => const PairSuccessCard(),
        _SetupStep.welcome || _SetupStep.error => _guide(),
        _ => _checklist(),
      };

  /// The guide, one page at a time, with the diagnostic first on a failure.
  Widget _guide() {
    final offset = _step == _SetupStep.error ? 1 : 0;

    return Column(
      children: <Widget>[
        SizedBox(
          height: _Fit.guide,
          child: PageView.builder(
            controller: _pages,
            itemCount: _pageCount,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) {
              if (offset == 1 && i == 0) {
                return PairErrorCard(message: _error!);
              }
              final index = i - offset;
              return PairGuidePage(
                index: index,
                total: pairGuideSteps.length,
                step: pairGuideSteps[index],
              );
            },
          ),
        ),
        const SizedBox(height: _Fit.gapBeforeDots),
        SizedBox(
          height: _Fit.dots,
          child: PairStepDots(
            count: _pageCount,
            index: _page,
            onTap: (i) {
              if (context.reduceMotion) {
                _pages.jumpToPage(i);
              } else {
                _pages.animateToPage(
                  i,
                  duration: MecMotion.fast,
                  curve: MecEasing.standard,
                );
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _checklist() {
    const labels = <String>[
      'Bluetooth permissions',
      'Scanning for MECAI-Watch',
      'Device discovered',
      'Establishing connection',
      'Subscribing to live data',
    ];
    const steps = <_SetupStep>[
      _SetupStep.permissions,
      _SetupStep.scanning,
      _SetupStep.found,
      _SetupStep.connecting,
      _SetupStep.handshake,
    ];

    return Column(
      children: <Widget>[
        for (var i = 0; i < labels.length; i++)
          PairStatusStep(
            label: labels[i],
            isDone: _step.index > steps[i].index,
            isActive: _step == steps[i],
          ),
        PairStatusStep(
          label: 'Ready!',
          isDone: _step == _SetupStep.connected,
          isActive: false,
          isLast: true,
        ),
      ],
    );
  }

  Widget _action() {
    final isWorking = _step.isActive;

    return _HoldToSkipButton(
      enabled: !isWorking,
      isRetry: _step == _SetupStep.error,
      label: isWorking
          ? _step.label
          : _step == _SetupStep.error
              ? 'Try Again'
              : 'Scan & Connect',
      onTap: isWorking ? null : _startConnection,
      onHeld: widget.onSkip,
    );
  }

  String get _title => switch (_step) {
        _SetupStep.welcome => 'Connect your MEC-AI watch',
        _SetupStep.error => 'Connection failed',
        _SetupStep.connected => "You're all set!",
        _ => 'Connecting…',
      };

  String get _subtitle => switch (_step) {
        _SetupStep.welcome =>
          'Pair once to stream heart rate, blood oxygen and temperature live.',
        _SetupStep.error => 'Check the steps below, then try again.',
        _SetupStep.connected => 'Your watch is paired and streaming.',
        _SetupStep.scanning => 'Looking for MECAI-Watch nearby…',
        _SetupStep.found => 'MECAI-Watch detected! Establishing connection…',
        _SetupStep.permissions =>
          'Bluetooth permissions are needed to discover the watch.',
        _SetupStep.connecting => 'Pairing with your MEC-AI watch…',
        _SetupStep.handshake => 'Setting up live vitals stream…',
      };
}

/// The setup screen's only action — and its hidden way out.
///
/// A tap runs the normal connection flow. Holding the button for
/// [holdToSkipDuration] instead sweeps a fill across it and continues into the
/// app without pairing: no separate "Skip" control is offered, so the screen
/// still asks first-time users to pair, but someone who cannot or will not pair
/// right now is never trapped.
///
/// The gesture stays quiet by design. Its one concession to discoverability is
/// feedback *while* it happens — the sweep, a tick on press-down and an impact
/// when it lands — plus a semantics label, so it is findable without being the
/// thing the eye is drawn to.
class _HoldToSkipButton extends StatefulWidget {
  const _HoldToSkipButton({
    required this.label,
    required this.isRetry,
    required this.enabled,
    required this.onTap,
    this.onHeld,
  });

  final String label;
  final bool isRetry;
  final bool enabled;
  final VoidCallback? onTap;

  /// Runs when the hold completes. Null disables the gesture entirely.
  final VoidCallback? onHeld;

  @override
  State<_HoldToSkipButton> createState() => _HoldToSkipButtonState();
}

/// How long the button must be held before the skip fires.
const Duration holdToSkipDuration = Duration(seconds: 3);

class _HoldToSkipButtonState extends State<_HoldToSkipButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: holdToSkipDuration,
    value: 0,
  )..addStatusListener(_onStatus);

  bool get _armed => widget.enabled && widget.onHeld != null;

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    HapticFeedback.mediumImpact();
    widget.onHeld?.call();
    // Reset for the next visit to this screen; the fill snaps back rather than
    // replaying its sweep in reverse over the transition.
    _hold.value = 0;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!_armed) return;
    HapticFeedback.selectionClick();
    _hold.forward();
  }

  void _onPointerEnd(PointerEvent event) {
    // A completed hold must not be undone by the finger lifting after the
    // callback already ran.
    if (_hold.status == AnimationStatus.completed) return;
    _hold.reverse();
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final holding = _hold.value > 0;

    return Semantics(
      label:
          '${widget.label}. Press and hold for 3 seconds to continue without '
          'pairing a watch.',
      child: MecPress(
        enabled: widget.enabled,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerUp: _onPointerEnd,
            onPointerCancel: _onPointerEnd,
          child: AnimatedBuilder(
            animation: _hold,
            builder: (context, child) => Stack(
              children: [
                FilledButton.icon(
                  onPressed: widget.onTap,
                  icon: widget.isRetry
                      ? const Icon(Icons.refresh)
                      : const Icon(Icons.bluetooth_searching),
                  label: Text(
                    holding ? 'Keep holding…' : widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // The sweep. Clipped to the button's own shape so the fill can
                // never read as a second element sitting behind it.
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: _hold.value,
                        child: Container(
                          color: Colors.white.withValues(alpha: 0.24),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
