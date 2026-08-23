/// Emergency contacts — who the SOS alert goes to, and which line it dials.
///
/// Reached from Profile. Set up here, calmly, in advance: the alternative is
/// discovering mid-emergency that there is nobody to send to, which is the one
/// moment this screen must never be needed.
///
/// Contacts stay on the device and are never uploaded — see [EmergencyContacts].
library;

import 'package:flutter/material.dart';

import '../data/emergency_contacts.dart';
import '../data/location_service.dart';
import '../data/sos_dispatcher.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../widgets/mec_card.dart';
import '../widgets/mec_press.dart';

class EmergencyContactsScreen extends StatefulWidget {
  const EmergencyContactsScreen({
    super.key,
    required this.contacts,
    required this.locationService,
    this.dispatcher = const SosDispatcher(),
  });

  final EmergencyContacts contacts;
  final LocationService locationService;
  final SosDispatcher dispatcher;

  @override
  State<EmergencyContactsScreen> createState() => _EmergencyContactsScreenState();
}

class _EmergencyContactsScreenState extends State<EmergencyContactsScreen> {
  /// Null until checked, so the UI can say "not checked yet" rather than implying
  /// permission was denied when it was merely never requested.
  bool? _locationGranted;
  bool? _smsGranted;

  @override
  void initState() {
    super.initState();
    widget.contacts.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.contacts.removeListener(_onChanged);
    super.dispose();
  }

  /// Requests SMS permission here rather than during an emergency.
  ///
  /// Without the grant the send throws and the alert never leaves, so this is the
  /// single most important thing to have settled before the feature is needed.
  Future<void> _checkSms() async {
    final granted = await widget.dispatcher.ensurePermission();
    if (!mounted) return;
    setState(() => _smsGranted = granted);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Requests location permission here rather than during an emergency.
  ///
  /// A permission dialog standing between someone and an ambulance is the wrong
  /// place to ask, so the prompt is moved to setup where a refusal costs nothing.
  Future<void> _checkLocation() async {
    final granted = await widget.locationService.ensurePermission();
    if (!mounted) return;
    setState(() => _locationGranted = granted);
  }

  Future<void> _edit({int? index}) async {
    final existing = index == null ? null : widget.contacts.contacts[index];
    final result = await showModalBottomSheet<EmergencyContact>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ContactEditor(contact: existing),
    );
    if (result == null) return;

    if (index == null) {
      await widget.contacts.add(result);
    } else {
      await widget.contacts.replaceAt(index, result);
    }
  }

  Future<void> _confirmRemove(int index) async {
    final contact = widget.contacts.contacts[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${contact.name}?'),
        content: const Text(
          'They will no longer be alerted when you trigger an SOS.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.contacts.removeAt(index);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final contacts = widget.contacts.contacts;
    final full = contacts.length >= EmergencyContacts.maxContacts;

    return Scaffold(
      appBar: AppBar(title: const Text('Emergency contacts')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          MecSpace.s16,
          MecSpace.s16,
          MecSpace.s16,
          MecSpace.s48,
        ),
        children: [
          if (contacts.isEmpty)
            MecCard(
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: MecRiskBand.moderate.color,
                    size: 20,
                  ),
                  const SizedBox(width: MecSpace.s12),
                  Expanded(
                    child: Text(
                      'No contacts yet. Pressing SOS will record the emergency and '
                      'your location, but there is nobody to notify.',
                      style: MecType.label.copyWith(
                        color: c.inkSecondary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            for (var i = 0; i < contacts.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: MecSpace.s8),
                child: _ContactRow(
                  contact: contacts[i],
                  isPrimary: i == 0,
                  onEdit: () => _edit(index: i),
                  onRemove: () => _confirmRemove(i),
                  onMakePrimary:
                      i == 0 ? null : () => widget.contacts.makePrimary(i),
                ),
              ),

          const SizedBox(height: MecSpace.s8),
          MecPress(
            enabled: !full,
            child: FilledButton.icon(
              onPressed: full ? null : () => _edit(),
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: Text(
                full
                    ? 'Maximum ${EmergencyContacts.maxContacts} contacts'
                    : 'Add a contact',
              ),
            ),
          ),
          if (contacts.length > 1) ...[
            const SizedBox(height: MecSpace.s8),
            Text(
              'The first contact is the primary. One SMS is addressed to everyone '
              'on this list.',
              style: MecType.label.copyWith(color: c.inkMuted, height: 1.4),
            ),
          ],

          const SizedBox(height: MecSpace.s32),
          Text(
            'Send permission',
            style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
          ),
          const SizedBox(height: MecSpace.s8),
          MecCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  SosDispatcher.isSupported
                      ? 'MEC-AI sends the emergency SMS itself, with no composer '
                          'and no tap. That needs Android’s SMS permission.'
                      : 'This platform does not allow an app to send SMS on its '
                          'own. The emergency and your location are still recorded '
                          'and uploaded to your server.',
                  style: MecType.label.copyWith(color: c.inkSecondary, height: 1.4),
                ),
                if (SosDispatcher.isSupported) ...[
                  const SizedBox(height: MecSpace.s12),
                  Row(
                    children: [
                      Icon(
                        switch (_smsGranted) {
                          true => Icons.check_circle_outline,
                          false => Icons.error_outline,
                          null => Icons.help_outline,
                        },
                        size: 16,
                        color: switch (_smsGranted) {
                          true => MecRiskBand.low.color,
                          false => MecRiskBand.high.color,
                          null => c.inkMuted,
                        },
                      ),
                      const SizedBox(width: MecSpace.s8),
                      Expanded(
                        child: Text(
                          switch (_smsGranted) {
                            true => 'SMS permission granted',
                            false => 'SMS permission denied — the alert cannot be '
                                'sent until this is allowed',
                            null => 'Permission not checked yet',
                          },
                          style: MecType.label.copyWith(color: c.inkSecondary),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: MecSpace.s12),
                  MecPress(
                    child: OutlinedButton.icon(
                      onPressed: _checkSms,
                      icon: const Icon(Icons.sms_outlined, size: 18),
                      label: const Text('Allow SMS sending'),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: MecSpace.s32),
          Text(
            'Location',
            style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
          ),
          const SizedBox(height: MecSpace.s8),
          MecCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The SOS message carries a Google Maps link to where you are. '
                  'Granting permission now means the alert is not waiting on a '
                  'prompt when you need it.',
                  style: MecType.label.copyWith(color: c.inkSecondary, height: 1.4),
                ),
                const SizedBox(height: MecSpace.s12),
                Row(
                  children: [
                    Icon(
                      switch (_locationGranted) {
                        true => Icons.check_circle_outline,
                        false => Icons.error_outline,
                        null => Icons.help_outline,
                      },
                      size: 16,
                      color: switch (_locationGranted) {
                        true => MecRiskBand.low.color,
                        false => MecRiskBand.high.color,
                        null => c.inkMuted,
                      },
                    ),
                    const SizedBox(width: MecSpace.s8),
                    Expanded(
                      child: Text(
                        switch (_locationGranted) {
                          true => 'Location permission granted',
                          false => 'Location is unavailable — check the app '
                              'permission and that location services are on',
                          null => 'Permission not checked yet',
                        },
                        style: MecType.label.copyWith(color: c.inkSecondary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: MecSpace.s12),
                MecPress(
                  child: OutlinedButton.icon(
                    onPressed: _checkLocation,
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text('Check location access'),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: MecSpace.s24),
          Text(
            'When SOS fires, MEC-AI records your location, sends each contact an '
            'SMS with a Google Maps link to where you are, and uploads the alert '
            'to your MEC-AI server. There is a five-second window to cancel a '
            'false alarm before anything is sent.',
            style: MecType.label.copyWith(color: c.inkMuted, height: 1.5),
          ),
          if (!widget.contacts.isPersistent) ...[
            const SizedBox(height: MecSpace.s16),
            Text(
              'Device storage is unavailable, so these contacts will be forgotten '
              'when the app restarts.',
              style: MecType.label.copyWith(color: MecRiskBand.moderate.color),
            ),
          ],
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.contact,
    required this.isPrimary,
    required this.onEdit,
    required this.onRemove,
    required this.onMakePrimary,
  });

  final EmergencyContact contact;
  final bool isPrimary;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback? onMakePrimary;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return MecCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      contact.name,
                      style: MecType.body.copyWith(color: c.inkPrimary),
                    ),
                    if (isPrimary) ...[
                      const SizedBox(width: MecSpace.s8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: MecSpace.s6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: c.series1.withValues(alpha: MecState.press),
                          borderRadius: BorderRadius.circular(MecRadius.pill),
                        ),
                        child: Text(
                          'Primary',
                          style: MecType.axisTick.copyWith(
                            color: c.series1,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: MecSpace.s2),
                Text(
                  contact.relationship == null || contact.relationship!.isEmpty
                      ? contact.phone
                      : '${contact.phone} · ${contact.relationship}',
                  style: MecType.label.copyWith(color: c.inkSecondary),
                ),
              ],
            ),
          ),
          if (onMakePrimary != null)
            IconButton(
              onPressed: onMakePrimary,
              icon: const Icon(Icons.arrow_upward, size: 18),
              tooltip: 'Make primary',
            ),
          IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: 'Edit',
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }
}

class _ContactEditor extends StatefulWidget {
  const _ContactEditor({this.contact});

  final EmergencyContact? contact;

  @override
  State<_ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends State<_ContactEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _relationship;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.contact?.name ?? '');
    _phone = TextEditingController(text: widget.contact?.phone ?? '');
    _relationship = TextEditingController(text: widget.contact?.relationship ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _relationship.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      EmergencyContact(
        name: _name.text.trim(),
        phone: EmergencyContacts.normalizePhone(_phone.text),
        relationship: _relationship.text.trim().isEmpty
            ? null
            : _relationship.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        MecSpace.s24,
        0,
        MecSpace.s24,
        // Clears the keyboard, so the save button is never behind it.
        MecSpace.s24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.contact == null ? 'Add a contact' : 'Edit contact',
              style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
            ),
            const SizedBox(height: MecSpace.s16),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              style: MecType.body.copyWith(color: c.inkPrimary),
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (raw) =>
                  (raw ?? '').trim().isEmpty ? 'Enter a name' : null,
            ),
            const SizedBox(height: MecSpace.s16),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              style: MecType.body.copyWith(color: c.inkPrimary),
              decoration: const InputDecoration(
                labelText: 'Mobile number',
                hintText: '0917 123 4567',
                helperText: 'Spaces and dashes are fine — they are stripped.',
              ),
              validator: (raw) => EmergencyContacts.isPlausiblePhone(raw ?? '')
                  ? null
                  : 'Enter a number that can be dialled',
            ),
            const SizedBox(height: MecSpace.s16),
            TextFormField(
              controller: _relationship,
              textCapitalization: TextCapitalization.sentences,
              style: MecType.body.copyWith(color: c.inkPrimary),
              decoration: const InputDecoration(
                labelText: 'Relationship (optional)',
                hintText: 'Daughter, neighbour, barangay health worker',
              ),
            ),
            const SizedBox(height: MecSpace.s24),
            MecPress(
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save contact'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
