/// Profile tab — who you are, and what the app knows about you.
///
/// Distinct from [ProfileScreen], which is the questionnaire *form*. This is the
/// destination the bottom nav points at: identity, how complete the profile is,
/// and the entry points to editing it, to the server settings, and to backup.
///
/// A form makes a poor tab — it opens with a keyboard and a save button that wants
/// to pop the route, neither of which a persistent destination should do.
library;

import 'package:flutter/material.dart';

import '../data/monitor_controller.dart';
import '../data/profile_registry.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import '../widgets/mec_bottom_nav.dart';
import '../widgets/mec_card.dart';
import '../widgets/mec_press.dart';
import 'emergency_contacts_screen.dart';
import 'profile_screen.dart';
import 'profile_switcher_screen.dart';
import 'settings_screen.dart';

class ProfileHubScreen extends StatelessWidget {
  const ProfileHubScreen({
    super.key,
    required this.controller,
    required this.registry,
    required this.onSwitchProfile,
  });

  final MonitorController controller;
  final ProfileRegistry registry;

  /// Performs a switch outside this widget's subtree — loading the new
  /// person's stores and re-binding the controller is app-shell work.
  ///
  /// [created] is true when [id] was just minted, so the caller can open the
  /// questionnaire right away instead of assuming a filled-in profile.
  final Future<void> Function(String id, bool created) onSwitchProfile;

  /// Which scoring inputs are still outstanding, in the order the form asks them.
  static const _fieldLabels = <String, String>{
    'total_cholesterol_mgdl': 'Total cholesterol',
    'hdl_cholesterol_mgdl': 'HDL cholesterol',
    'systolic_mmhg': 'Resting blood pressure',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final profiles = controller.profileStore;
    final settings = controller.settings;

    return ListenableBuilder(
      // Both stores, because the name and the sync state live in different ones.
      listenable: Listenable.merge([
        profiles,
        settings,
        controller,
        controller.emergencyContacts,
      ]),
      builder: (context, _) {
        final profile = profiles.profile;
        final missing = profile.missingForScoring;
        final name = profiles.resolvedDisplayName(settings.patientId);

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            MecSpace.s16,
            MecSpace.s24,
            MecSpace.s16,
            // Clears the floating nav, so the last row is reachable.
            MecBottomNav.reservedHeight,
          ),
          children: [
            // ── who is wearing the watch ──
            MecCard(
              onTap: () => _manageProfiles(context),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Profiles',
                          style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
                        ),
                        const SizedBox(height: MecSpace.s2),
                        Text(
                          registry.count == 1
                              ? 'One person on this phone. Add another to switch.'
                              : '${registry.count} people on this phone. '
                                  'Readings follow the person you pick.',
                          style: MecType.label.copyWith(color: c.inkSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: MecSpace.s12),
                  Icon(
                    Icons.swap_horiz_rounded,
                    size: 20,
                    color: c.series1,
                  ),
                ],
              ),
            ),
            const SizedBox(height: MecSpace.s24),

            // ── identity ──
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: c.series1.withValues(alpha: MecState.press),
                    shape: BoxShape.circle,
                    border: Border.all(color: c.hairline),
                  ),
                  child: Center(
                    child: Text(
                      _initials(name),
                      style: MecType.statValue.copyWith(
                        color: c.series1,
                        fontSize: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: MecSpace.s16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: MecType.sectionTitle.copyWith(
                          color: c.inkPrimary,
                          fontSize: 22,
                        ),
                      ),
                      const SizedBox(height: MecSpace.s2),
                      Text(
                        profiles.displayName.trim().isEmpty
                            ? 'Add your name so it appears with your readings'
                            : '${profile.age} · ${profile.sexMale ? 'Male' : 'Female'}',
                        style: MecType.label.copyWith(color: c.inkSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: MecSpace.s24),

            // ── completeness ──
            MecCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        missing.isEmpty
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                        size: 18,
                        color: missing.isEmpty
                            ? MecRiskBand.low.color
                            : MecRiskBand.moderate.color,
                      ),
                      const SizedBox(width: MecSpace.s8),
                      Expanded(
                        child: Text(
                          missing.isEmpty
                              ? 'Profile complete — the ten-year score can be computed'
                              : 'The ten-year score needs a little more',
                          style: MecType.body.copyWith(color: c.inkPrimary),
                        ),
                      ),
                    ],
                  ),
                  if (missing.isNotEmpty) ...[
                    const SizedBox(height: MecSpace.s12),
                    for (final field in missing)
                      Padding(
                        padding: const EdgeInsets.only(bottom: MecSpace.s6),
                        child: Row(
                          children: [
                            Icon(Icons.remove, size: 14, color: c.inkMuted),
                            const SizedBox(width: MecSpace.s8),
                            Text(
                              _fieldLabels[field] ?? field,
                              style: MecType.label.copyWith(color: c.inkSecondary),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: MecSpace.s4),
                    Text(
                      // Says why, not just what: the watch physically cannot supply
                      // these, so "take another reading" would be useless advice.
                      'The watch measures heart rate and blood oxygen directly. '
                      'Cholesterol comes from a lipid panel and blood pressure '
                      'from a cuff, so both have to come from you.',
                      style: MecType.label.copyWith(color: c.inkMuted, height: 1.4),
                    ),
                  ],
                  const SizedBox(height: MecSpace.s16),
                  MecPress(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ProfileScreen(store: profiles),
                        ),
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: Text(
                        missing.isEmpty ? 'Edit health profile' : 'Complete profile',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: MecSpace.s16),

            // ── measurements on file ──
            MecCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'On file',
                    style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
                  ),
                  const SizedBox(height: MecSpace.s12),
                  _Row(
                    label: 'Resting blood pressure',
                    value: profile.baselineSystolicMmHg == null
                        ? VitalsReading.absent
                        : '${profile.baselineSystolicMmHg!.round()} mmHg',
                  ),
                  _Row(
                    label: 'Total cholesterol',
                    value: profile.totalCholesterolMgdl == null
                        ? VitalsReading.absent
                        : '${profile.totalCholesterolMgdl!.round()} mg/dL',
                  ),
                  _Row(
                    label: 'HDL cholesterol',
                    value: profile.hdlCholesterolMgdl == null
                        ? VitalsReading.absent
                        : '${profile.hdlCholesterolMgdl!.round()} mg/dL',
                  ),
                  _Row(label: 'Smoker', value: profile.smoker ? 'Yes' : 'No'),
                  _Row(label: 'Diabetic', value: profile.diabetic ? 'Yes' : 'No'),
                  _Row(
                    label: 'Blood-pressure medication',
                    value: profile.onBpMedication ? 'Yes' : 'No',
                  ),
                ],
              ),
            ),
            const SizedBox(height: MecSpace.s16),

            // ── emergency contacts ──
            MecCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Emergency contacts',
                          style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
                        ),
                      ),
                      if (controller.emergencyContacts.isEmpty)
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 18,
                          color: MecRiskBand.moderate.color,
                        ),
                    ],
                  ),
                  const SizedBox(height: MecSpace.s8),
                  Text(
                    controller.emergencyContacts.isEmpty
                        // Names the consequence rather than just the gap: an SOS
                        // with nobody to notify still records, and the user should
                        // know that is the state they are in.
                        ? 'Nobody is set. Pressing SOS will record the emergency '
                            'and your location, but no message will be sent.'
                        : controller.emergencyContacts.contacts
                            .map((contact) => contact.name)
                            .join(', '),
                    style: MecType.label.copyWith(
                      color: controller.emergencyContacts.isEmpty
                          ? MecRiskBand.moderate.color
                          : c.inkSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: MecSpace.s8),
                  _Row(
                    label: 'On SOS',
                    value: 'SMS with map link',
                  ),
                  const SizedBox(height: MecSpace.s16),
                  MecPress(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => EmergencyContactsScreen(
                            contacts: controller.emergencyContacts,
                            locationService: controller.locationService,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.contact_phone_outlined, size: 18),
                      label: Text(
                        controller.emergencyContacts.isEmpty
                            ? 'Add an emergency contact'
                            : 'Manage contacts',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: MecSpace.s16),

            // ── server & backup ──
            MecCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Server & backup',
                    style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
                  ),
                  const SizedBox(height: MecSpace.s12),
                  _Row(label: 'Address', value: settings.apiBaseUrl),
                  _Row(
                    label: 'Backup',
                    value: settings.backupEnabled ? 'On' : 'Off',
                  ),
                  _Row(
                    label: 'Waiting to upload',
                    value: '${controller.syncService?.pendingCount ?? 0}',
                  ),
                  const SizedBox(height: MecSpace.s16),
                  MecPress(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SettingsScreen(
                            settings: settings,
                            riskService: controller.riskService,
                            profiles: profiles,
                            syncService: controller.syncService,
                            readingStore: controller.store,
                            source: controller.bleSource,
                            controller: controller,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      label: const Text('Server settings'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: MecSpace.s16),

            // Persistent, because it is a product requirement rather than a
            // legal footnote (see README → Privacy).
            Text(
              'Screening indicator, not a diagnosis. Consult a physician.',
              textAlign: TextAlign.center,
              style: MecType.label.copyWith(color: c.inkMuted),
            ),
          ],
        );
      },
    );
  }

  /// Opens the switcher and carries its result out to the app shell.
  ///
  /// A brand-new profile lands the user straight in the questionnaire: a person
  /// with no answers is exactly the state the rest of this screen is built to
  /// explain, but someone who just tapped "Add person" should be shown where
  /// those answers go, not left on a list.
  Future<void> _manageProfiles(BuildContext context) async {
    final result = await showProfileSwitcher(context, registry: registry);
    if (result == null || !context.mounted) return;
    if (!result.created && result.id == registry.activeId) return;
    await onSwitchProfile(result.id, result.created);
    if (!context.mounted) return;
    if (result.created) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ProfileScreen(store: controller.profileStore),
        ),
      );
    }
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  /// Public so the profile switcher can render the same initials without
  /// duplicating the derivation.
  static String initialsOf(String name) => _initials(name);
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MecSpace.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: MecType.label.copyWith(color: c.inkSecondary),
            ),
          ),
          const SizedBox(width: MecSpace.s12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: MecType.label.copyWith(
                color: c.inkPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
