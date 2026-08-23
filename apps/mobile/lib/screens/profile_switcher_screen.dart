/// Pick who the phone is monitoring right now.
///
/// Opened from [ProfileHubScreen]. Choosing a row pops with that profile's id;
/// "Add person" creates one first and pops with it flagged as new, so the
/// caller can land the user straight in the questionnaire. The caller — not
/// this screen — performs the actual switch, because swapping the live stores
/// is an app-shell concern and this screen may be popped for either reason.
library;

import 'package:flutter/material.dart';

import '../data/profile_registry.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../widgets/mec_card.dart';
import 'profile_hub_screen.dart';

/// What [ProfileSwitcherScreen] hands back on pop.
class ProfileSwitchResult {
  const ProfileSwitchResult({required this.id, required this.created});

  final String id;

  /// True when the id was minted by this screen's add flow, so the caller can
  /// open the questionnaire instead of assuming a filled-in profile.
  final bool created;
}

/// Opens the switcher and returns what was chosen, or null on back/dismiss.
Future<ProfileSwitchResult?> showProfileSwitcher(
  BuildContext context, {
  required ProfileRegistry registry,
}) =>
    Navigator.of(context).push<ProfileSwitchResult>(
      MaterialPageRoute(
        builder: (_) => ProfileSwitcherScreen(registry: registry),
      ),
    );

class ProfileSwitcherScreen extends StatelessWidget {
  const ProfileSwitcherScreen({super.key, required this.registry});

  final ProfileRegistry registry;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return Scaffold(
      appBar: AppBar(title: const Text('Profiles')),
      body: ListenableBuilder(
        listenable: registry,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(MecSpace.s16),
            children: [
              Text(
                'Who is wearing the watch? Readings, alerts and the SOS '
                'contact list follow the person you pick.',
                style: MecType.label.copyWith(color: c.inkSecondary, height: 1.4),
              ),
              const SizedBox(height: MecSpace.s16),
              for (final id in registry.ids)
                Padding(
                  padding: const EdgeInsets.only(bottom: MecSpace.s8),
                  child: _ProfileTile(
                    name: _resolvedName(id),
                    patientId: id,
                    active: id == registry.activeId,
                    onTap: () => Navigator.of(context).pop(
                      ProfileSwitchResult(id: id, created: false),
                    ),
                  ),
                ),
              const SizedBox(height: MecSpace.s8),
              MecCard(
                onTap: () async {
                  final id = await registry.create();
                  if (context.mounted) {
                    Navigator.of(context).pop(
                      ProfileSwitchResult(id: id, created: true),
                    );
                  }
                },
                border: c.hairline,
                surface: Colors.transparent,
                padding: const EdgeInsets.symmetric(
                  horizontal: MecSpace.s16,
                  vertical: MecSpace.s12,
                ),
                child: Row(
                  children: [
                    Icon(Icons.person_add_alt_1_outlined,
                        size: 22, color: c.series1),
                    const SizedBox(width: MecSpace.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Add person',
                            style: MecType.body.copyWith(
                              color: c.series1,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Starts a fresh health questionnaire',
                            style: MecType.label.copyWith(color: c.inkMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _resolvedName(String id) {
    final stored = registry.displayNameOf(id).trim();
    if (stored.isNotEmpty) return stored;
    return 'Patient ${id.replaceAll('-', '').substring(0, 8)}';
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.name,
    required this.patientId,
    required this.active,
    required this.onTap,
  });

  final String name;
  final String patientId;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return MecCard(
      onTap: onTap,
      border: active ? c.series1 : c.hairline,
      // The selected row carries the same pressed-tint recipe every other
      // selection in the app uses, rather than a new colour.
      surface: active
          ? Color.alphaBlend(c.series1.withValues(alpha: MecState.press), c.card)
          : null,
      padding: const EdgeInsets.symmetric(
        horizontal: MecSpace.s12,
        vertical: MecSpace.s8,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.series1.withValues(alpha: MecState.press),
              shape: BoxShape.circle,
              border: Border.all(color: c.hairline),
            ),
            alignment: Alignment.center,
            child: Text(
              ProfileHubScreen.initialsOf(name),
              style: MecType.label.copyWith(
                color: c.series1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: MecSpace.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: MecType.body.copyWith(
                    color: c.inkPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'ID ${patientId.substring(0, 8)}',
                  style: MecType.label.copyWith(color: c.inkMuted),
                ),
              ],
            ),
          ),
          Icon(
            active ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: active ? c.series1 : c.inkMuted,
          ),
        ],
      ),
    );
  }
}
