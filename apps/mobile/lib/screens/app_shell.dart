/// The app's navigation frame: four destinations over one shared controller.
///
/// ### Why a PageView rather than an IndexedStack
///
/// A tap animates the pages horizontally, which is the "fluid" part — and unlike
/// swapping children in an `AnimatedSwitcher`, a `PageView` keeps each page's
/// state and scroll offset. Returning to Analytics lands where you left it instead
/// of scrolling itself back to the calendar.
///
/// Swiping is disabled. Home carries the SOS button, and a horizontal drag that
/// slides pages under a thumb reaching for it is exactly the wrong behaviour on a
/// screen someone opens while unwell.
///
/// ### Motion
///
/// Under reduced motion the pages jump rather than slide: docs/design.md §3.6
/// treats sliding full-screen content as a vestibular trigger, and the
/// destination is conveyed by the nav indicator, not by the travel.
library;

import 'package:flutter/material.dart';

import '../data/monitor_controller.dart';
import '../data/profile_registry.dart';
import '../data/server_status.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import '../widgets/acute_alert_banner.dart';
import '../widgets/alerts_popup.dart';
import '../widgets/mec_bottom_nav.dart';
import 'analytics_screen.dart';
import 'home_screen.dart';
import 'profile_hub_screen.dart';
import 'sos_emergency_screen.dart';
import 'vitals_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
    required this.registry,
    required this.onSwitchProfile,
    required this.serverStatus,
  });

  final MonitorController controller;
  final ProfileRegistry registry;

  /// Live reachability of the scoring server — the header's green/white
  /// server button reads this.
  final ServerStatus serverStatus;

  /// See [ProfileHubScreen.onSwitchProfile]; passed through to the profile tab.
  final Future<void> Function(String id, bool created) onSwitchProfile;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _pageController = PageController();
  int _index = 0;

  /// The live emergency route, while one is up.
  ///
  /// A [Route] rather than a bool, because this has to answer two questions a
  /// flag cannot: *which* route to take down, and whether it is still standing.
  /// The screen pops itself when cancelled there, so by the time the controller
  /// notifies us the route may already be gone.
  MaterialPageRoute<void>? _sosRoute;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    // Questionnaire edits reach the scoring path via the controller's own
    // subscription to the profile store — which must survive profile swaps, so
    // it cannot live on this widget whose listeners are bound at mount.
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _pageController.dispose();
    super.dispose();
  }

  /// The watch's SOS button arrives over BLE, so the emergency screen has to be
  /// raised from here — it must appear whichever tab the user happens to be on.
  void _onControllerChanged() {
    if (!mounted) return;
    final active = widget.controller.sosActive;

    if (active && _sosRoute == null) {
      final route = MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => SosEmergencyScreen(
          latestReading: widget.controller.latest,
          onCancelSos: _cancelSos,
          controller: widget.controller,
        ),
      );
      _sosRoute = route;
      Navigator.of(context).push(route).then((_) {
        _sosRoute = null;
        if (widget.controller.sosActive) _cancelSos();
      });
    } else if (!active && _sosRoute != null) {
      final route = _sosRoute!;
      _sosRoute = null;

      // Only if it is still on the stack. Cancelling from the screen pops it and
      // *then* notifies us, so this arm usually finds the route already gone —
      // popping again would take this shell's own route with it and leave an
      // empty navigator, which paints as a black screen. The removal is for the
      // case the screen cannot handle itself: a cancel pressed on the watch.
      if (route.isCurrent) {
        Navigator.of(context).pop();
      } else if (route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    }
    setState(() {});
  }

  void _cancelSos() {
    widget.controller.setSosActive(false);
    widget.controller.sendSosToWatch();
  }

  /// Alerts is a popup, not a page — it has no `PageView` child, so tapping it
  /// must not move the pager or leave the destination looking selected.
  static const _alertsIndex = 2;

  void _select(int index) {
    if (index == _alertsIndex) {
      showAcuteAlertsPopup(
        context,
        flags: widget.controller.acuteFlags,
        contacts: widget.controller.emergencyContacts,
        locationService: widget.controller.locationService,
      );
      return;
    }
    // Alerts occupies slot 2, so every destination after it is one ahead of its
    // page.
    final page = index > _alertsIndex ? index - 1 : index;
    if (index == _index) return;
    setState(() => _index = index);
    if (context.reduceMotion) {
      _pageController.jumpToPage(page);
    } else {
      _pageController.animateToPage(
        page,
        duration: MecMotion.fast,
        curve: MecEasing.standard,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    final flags = controller.acuteFlags;

    // The badge counts findings that need acting on. Info-level notes are not
    // alarms and would inflate a number the user reads as "things wrong".
    final urgent = flags
        .where((f) => f.severity == Severity.critical || f.severity == Severity.warning)
        .length + (controller.emergencyContacts.isEmpty ? 1 : 0);

    return Scaffold(
      body: Stack(
        children: [
          // Column, not an overlay: the banner pushes the page down rather than
          // covering the top of it. Hiding a vital reading in order to warn about
          // a vital reading is worse than the problem.
          Column(
            children: [
              SafeArea(
                bottom: false,
                child: AcuteAlertBanner(
                  flags: flags,
                  contactsMissing: controller.emergencyContacts.isEmpty,
                  onView: () => showAcuteAlertsPopup(
                    context,
                    flags: flags,
                    contacts: controller.emergencyContacts,
                    locationService: controller.locationService,
                  ),
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (page) => setState(
                    () => _index = page >= _alertsIndex ? page + 1 : page,
                  ),
                  children: [
                    SafeArea(
                      bottom: false,
                      child: HomeScreen(
                        controller: controller,
                        serverStatus: widget.serverStatus,
                      ),
                    ),
                    SafeArea(
                      bottom: false,
                      child: VitalsScreen(controller: controller),
                    ),
                    SafeArea(
                      bottom: false,
                      child: AnalyticsScreen(controller: controller),
                    ),
                    SafeArea(
                      bottom: false,
                      child: ProfileHubScreen(
                        controller: controller,
                        registry: widget.registry,
                        onSwitchProfile: widget.onSwitchProfile,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: MecBottomNav(
                currentIndex: _index,
                onSelect: _select,
                destinations: [
                  const MecNavDestination(
                    icon: Icons.monitor_heart_outlined,
                    selectedIcon: Icons.monitor_heart,
                    label: 'Home',
                  ),
                  const MecNavDestination(
                    icon: Icons.favorite_outline,
                    selectedIcon: Icons.favorite,
                    label: 'Vitals',
                  ),
                  MecNavDestination(
                    icon: Icons.notifications_none_rounded,
                    selectedIcon: Icons.notifications_active_rounded,
                    label: 'Alerts',
                    badgeCount: urgent,
                  ),
                  const MecNavDestination(
                    icon: Icons.insights_outlined,
                    selectedIcon: Icons.insights,
                    label: 'Trends',
                  ),
                  const MecNavDestination(
                    icon: Icons.person_outline,
                    selectedIcon: Icons.person,
                    label: 'Profile',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
