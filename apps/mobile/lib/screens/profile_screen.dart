/// The health questionnaire — what the watch cannot sense.
///
/// This is what the ring's "Complete your profile" chip opens. Before it existed
/// that chip was wired to an empty callback, so it looked tappable and did nothing.
///
/// ### Why a systolic field is here
///
/// The Framingham model needs age, sex, smoking, diabetes, both cholesterols *and*
/// a systolic pressure. The MEC-AI watch has no cuff — it streams heart rate, SpO2
/// and temperature — so on this hardware the score can only ever be computed from
/// a resting systolic the user supplies. That is why it sits in the questionnaire
/// beside the lipid panel rather than being waited on from the device.
///
/// Ranges match the service's own validators (`services/api/.../models.py`), so a
/// profile that scores on-device is also one the server will accept.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/profile_store.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import '../widgets/mec_card.dart';
import '../widgets/mec_press.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.store});

  final ProfileStore store;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _form = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _age;
  late final TextEditingController _systolic;
  late final TextEditingController _diastolic;
  late final TextEditingController _totalChol;
  late final TextEditingController _hdlChol;

  late bool _sexMale;
  late bool _smoker;
  late bool _diabetic;
  late bool _onBpMedication;
  late bool _familyHistory;

  @override
  void initState() {
    super.initState();
    final p = widget.store.profile;

    _name = TextEditingController(text: widget.store.displayName);
    _age = TextEditingController(text: '${p.age}');
    _systolic = TextEditingController(text: _num(p.baselineSystolicMmHg));
    _diastolic = TextEditingController(text: _num(p.baselineDiastolicMmHg));
    _totalChol = TextEditingController(text: _num(p.totalCholesterolMgdl));
    _hdlChol = TextEditingController(text: _num(p.hdlCholesterolMgdl));

    _sexMale = p.sexMale;
    _smoker = p.smoker;
    _diabetic = p.diabetic;
    _onBpMedication = p.onBpMedication;
    _familyHistory = p.familyHistoryCvd;
  }

  static String _num(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? '${v.round()}' : '$v');

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _systolic.dispose();
    _diastolic.dispose();
    _totalChol.dispose();
    _hdlChol.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;

    // Saved before the profile, because `save` is what notifies listeners — and
    // the sync service re-enrols on that notification. Setting the name after
    // would leave the server showing the previous one until the next edit.
    await widget.store.setDisplayName(_name.text);

    await widget.store.save(
      RiskProfile(
        age: int.parse(_age.text.trim()),
        sexMale: _sexMale,
        smoker: _smoker,
        diabetic: _diabetic,
        onBpMedication: _onBpMedication,
        familyHistoryCvd: _familyHistory,
        totalCholesterolMgdl: double.tryParse(_totalChol.text.trim()),
        hdlCholesterolMgdl: double.tryParse(_hdlChol.text.trim()),
        baselineSystolicMmHg: double.tryParse(_systolic.text.trim()),
        baselineDiastolicMmHg: double.tryParse(_diastolic.text.trim()),
      ),
    );

    if (mounted) Navigator.of(context).pop();
  }

  /// Optional field: blank is allowed, but a value present must be plausible.
  String? _optional(String? raw, double min, double max, String unit) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null) return 'Enter a number';
    if (value < min || value > max) {
      return 'Expected $min–$max $unit';
    }
    return null;
  }

  /// Diastolic, cross-checked against the systolic beside it.
  ///
  /// Range alone is not enough: 120/140 passes both bounds individually and is
  /// still not a blood pressure. Caught here rather than in the estimator, so the
  /// user is told at the point they can fix it.
  String? _validateDiastolic(String? raw) {
    final range = _optional(
      raw,
      MecPlausible.diastolicMin,
      MecPlausible.diastolicMax,
      'mmHg',
    );
    if (range != null) return range;

    final dia = double.tryParse((raw ?? '').trim());
    final sys = double.tryParse(_systolic.text.trim());
    if (dia == null || sys == null) return null;
    if (dia >= sys) return 'Must be below the systolic ($sys)';
    if (sys - dia < 20) return 'Gap from the systolic looks too small';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Scaffold(
      appBar: AppBar(title: const Text('Health profile')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            MecSpace.s16,
            MecSpace.s8,
            MecSpace.s16,
            MecSpace.s48,
          ),
          children: [
            _MissingBanner(profile: widget.store.profile),
            const SizedBox(height: MecSpace.s24),

            _Section(
              title: 'About you',
              subtitle: 'Used by the model and never sent anywhere but your '
                  'scoring server.',
              children: [
                TextFormField(
                  controller: _name,
                  keyboardType: TextInputType.name,
                  textCapitalization: TextCapitalization.words,
                  style: MecType.body.copyWith(color: c.inkPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    helperText: 'Shown beside your readings on the clinician '
                        'dashboard. Leave blank to stay pseudonymous.',
                  ),
                  // Optional on purpose. A required real name would make
                  // monitoring conditional on identifying yourself, and the
                  // dashboard falls back to a device-derived label.
                  validator: (raw) => (raw ?? '').trim().length > 80
                      ? 'Keep it under 80 characters'
                      : null,
                ),
                const SizedBox(height: MecSpace.s16),
                TextFormField(
                  controller: _age,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: MecType.body.copyWith(color: c.inkPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Age',
                    suffixText: 'years',
                  ),
                  validator: (raw) {
                    final value = int.tryParse((raw ?? '').trim());
                    if (value == null) return 'Enter your age';
                    if (value < 18 || value > 110) return 'Expected 18–110';
                    return null;
                  },
                ),
                const SizedBox(height: MecSpace.s16),
                _SexPicker(
                  sexMale: _sexMale,
                  onChanged: (v) => setState(() => _sexMale = v),
                ),
              ],
            ),

            const SizedBox(height: MecSpace.s24),
            _Section(
              title: 'Clinical measurements',
              subtitle: 'From a clinic visit, a home cuff, or a lipid panel. '
                  'Leave blank rather than guessing — a made-up number produces '
                  'a confident-looking score with nothing behind it.',
              children: [
                TextFormField(
                  controller: _systolic,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: MecType.body.copyWith(color: c.inkPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Resting systolic blood pressure',
                    suffixText: 'mmHg',
                    helperText: 'The upper number, e.g. 128. Your watch has no '
                        'cuff, so the score needs this from you.',
                  ),
                  validator: (raw) => _optional(
                    raw,
                    MecPlausible.systolicMin,
                    MecPlausible.systolicMax,
                    'mmHg',
                  ),
                  // The estimate on the Vitals tab is anchored to this pair, so a
                  // change here has to re-validate the other half of it.
                  onChanged: (_) => _form.currentState?.validate(),
                ),
                const SizedBox(height: MecSpace.s16),
                TextFormField(
                  controller: _diastolic,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: MecType.body.copyWith(color: c.inkPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Resting diastolic blood pressure',
                    suffixText: 'mmHg',
                    helperText: 'The lower number, e.g. 82. With the systolic '
                        'above, the app can estimate your pressure from your '
                        'heart rate and blood oxygen.',
                  ),
                  validator: _validateDiastolic,
                  onChanged: (_) => _form.currentState?.validate(),
                ),
                const SizedBox(height: MecSpace.s16),
                TextFormField(
                  controller: _totalChol,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: MecType.body.copyWith(color: c.inkPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Total cholesterol',
                    suffixText: 'mg/dL',
                  ),
                  validator: (raw) => _optional(raw, 100, 450, 'mg/dL'),
                ),
                const SizedBox(height: MecSpace.s16),
                TextFormField(
                  controller: _hdlChol,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: MecType.body.copyWith(color: c.inkPrimary),
                  decoration: const InputDecoration(
                    labelText: 'HDL cholesterol',
                    suffixText: 'mg/dL',
                    helperText: 'The "good" cholesterol, listed separately on a '
                        'lipid panel.',
                  ),
                  validator: (raw) => _optional(raw, 10, 150, 'mg/dL'),
                ),
              ],
            ),

            const SizedBox(height: MecSpace.s24),
            _Section(
              title: 'History',
              children: [
                _Toggle(
                  title: 'I currently smoke',
                  value: _smoker,
                  onChanged: (v) => setState(() => _smoker = v),
                ),
                _Toggle(
                  title: 'I have diabetes',
                  value: _diabetic,
                  onChanged: (v) => setState(() => _diabetic = v),
                ),
                _Toggle(
                  title: 'I take blood-pressure medication',
                  subtitle: 'Changes how systolic pressure is weighted.',
                  value: _onBpMedication,
                  onChanged: (v) => setState(() => _onBpMedication = v),
                ),
                _Toggle(
                  title: 'Family history of heart disease',
                  subtitle: 'Recorded for your clinician. Not an input to the '
                      'Framingham model.',
                  value: _familyHistory,
                  onChanged: (v) => setState(() => _familyHistory = v),
                ),
              ],
            ),

            if (!widget.store.isPersistent) ...[
              const SizedBox(height: MecSpace.s16),
              MecCard.status(
                MecRiskBand.moderate.color,
                child: Text(
                  'Device storage is unavailable, so this profile works for now '
                  'but resets when the app restarts.',
                  style: MecType.axisTick.copyWith(
                    color: c.inkPrimary,
                    height: 1.4,
                  ),
                ),
              ),
            ],

            const SizedBox(height: MecSpace.s32),
            MecPress(
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check_rounded, size: 20),
                label: const Text('Save profile'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// States plainly what is still missing and what supplying it unlocks.
class _MissingBanner extends StatelessWidget {
  const _MissingBanner({required this.profile});

  final RiskProfile profile;

  static const _labels = <String, String>{
    'total_cholesterol_mgdl': 'Total cholesterol',
    'hdl_cholesterol_mgdl': 'HDL cholesterol',
    'systolic_mmhg': 'Resting systolic blood pressure',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final missing = profile.missingForScoring;

    if (missing.isEmpty) {
      return MecCard.status(
        MecRiskBand.low.color,
        child: Row(
          children: [
            Icon(Icons.check_circle_outline,
                size: 18, color: MecRiskBand.low.color),
            const SizedBox(width: MecSpace.s12),
            Expanded(
              child: Text(
                'Your profile is complete — the 10-year score is being '
                'calculated on this device.',
                style: MecType.axisTick.copyWith(
                  color: c.inkPrimary,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return MecCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.assignment_outlined, size: 18, color: c.series1),
              const SizedBox(width: MecSpace.s12),
              Expanded(
                child: Text(
                  '${missing.length} field${missing.length == 1 ? '' : 's'} '
                  'needed for a 10-year score',
                  style: MecType.label.copyWith(color: c.inkPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          for (final field in missing)
            Padding(
              padding: const EdgeInsets.only(top: MecSpace.s4),
              child: Row(
                children: [
                  Icon(Icons.remove, size: 12, color: c.inkMuted),
                  const SizedBox(width: MecSpace.s8),
                  Text(
                    _labels[field] ?? field,
                    style: MecType.axisTick.copyWith(color: c.inkSecondary),
                  ),
                ],
              ),
            ),
          const SizedBox(height: MecSpace.s12),
          Text(
            'Heart rate, blood oxygen and temperature keep streaming, and '
            'immediate alerts keep firing, with or without these.',
            style: MecType.axisTick.copyWith(color: c.inkMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: MecType.sectionTitle.copyWith(color: c.inkPrimary)),
        if (subtitle != null) ...[
          const SizedBox(height: MecSpace.s4),
          Text(
            subtitle!,
            style: MecType.label.copyWith(color: c.inkSecondary, height: 1.4),
          ),
        ],
        const SizedBox(height: MecSpace.s16),
        ...children,
      ],
    );
  }
}

/// Sex as an MD3 segmented button — two mutually exclusive pills.
class _SexPicker extends StatelessWidget {
  const _SexPicker({required this.sexMale, required this.onChanged});

  final bool sexMale;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: MecSpace.s16),
          child: Text(
            'Sex',
            style: MecType.label.copyWith(color: c.inkSecondary),
          ),
        ),
        Expanded(
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(value: true, label: Text('Male')),
              ButtonSegment<bool>(value: false, label: Text('Female')),
            ],
            selected: {sexMale},
            showSelectedIcon: false,
            onSelectionChanged: (set) => onChanged(set.first),
          ),
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Padding(
      padding: const EdgeInsets.only(bottom: MecSpace.s8),
      child: MecCard(
        onTap: () => onChanged(!value),
        padding: const EdgeInsets.symmetric(
          horizontal: MecSpace.s16,
          vertical: MecSpace.s8,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: MecType.body.copyWith(color: c.inkPrimary),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: MecType.axisTick.copyWith(
                        color: c.inkMuted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: MecSpace.s12),
            // Excluded because the whole card is already the control — the switch
            // would otherwise be announced as a second, separate one.
            ExcludeSemantics(
              child: Switch(value: value, onChanged: onChanged),
            ),
          ],
        ),
      ),
    );
  }
}
