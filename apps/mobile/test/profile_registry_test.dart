/// Tests for multi-profile support: the registry's pointer semantics, the
/// migration from a single-profile install, and the per-profile namespacing of
/// the profile and emergency-contact stores.
///
/// The stakes here are misattribution, not mere inconvenience: a reading
/// uploaded under the wrong patient id becomes a wrong fact on a clinical
/// dashboard. So the tests lean on the identity cases — who owns what after
/// create/switch, and what an upgraded install keeps.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/emergency_contacts.dart';
import 'package:mecai_mobile/data/profile_registry.dart';
import 'package:mecai_mobile/data/profile_store.dart';
import 'package:mecai_mobile/data/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const legacyId = '11111111-2222-3333-4444-555555555555';

  group('ProfileRegistry.load', () {
    test('a fresh install seeds one profile from the minted id', () async {
      SharedPreferences.setMockInitialValues({});
      final registry = await ProfileRegistry.load(
        seedPatientId: await _mintedId(),
      );

      expect(registry.count, 1);
      expect(registry.activeId, registry.ids.single);
      expect(registry.legacyId, registry.activeId);
    });

    test('an existing single-profile install is adopted with its identity',
        () async {
      SharedPreferences.setMockInitialValues({
        'patient_id': legacyId,
        'profile_display_name': 'Maria Santos',
      });

      final registry = await ProfileRegistry.load(seedPatientId: legacyId);

      expect(registry.ids, [legacyId]);
      expect(registry.activeId, legacyId);
      expect(registry.legacyId, legacyId);
      // The name is carried across so the switcher can render it for this
      // profile even while another is active.
      expect(registry.displayNameOf(legacyId), 'Maria Santos');
    });

    test('the index survives a restart unchanged', () async {
      SharedPreferences.setMockInitialValues({'patient_id': legacyId});
      final first = await ProfileRegistry.load(seedPatientId: legacyId);
      final second = await ProfileRegistry.load(seedPatientId: 'irrelevant');

      expect(second.ids, first.ids);
      expect(second.activeId, first.activeId);
    });

    test('legacy display-name fallback only applies to the adopted profile',
        () async {
      SharedPreferences.setMockInitialValues({
        'patient_id': legacyId,
        'profile_display_name': 'Maria Santos',
      });
      final registry = await ProfileRegistry.load(seedPatientId: legacyId);
      final other = await registry.create();

      expect(registry.displayNameOf(other), '');
    });
  });

  group('create and switch', () {
    late ProfileRegistry registry;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'patient_id': legacyId});
      registry = await ProfileRegistry.load(seedPatientId: legacyId);
    });

    test('create mints a distinct id and makes it active', () async {
      final created = await registry.create();

      expect(created, isNot(legacyId));
      expect(registry.count, 2);
      expect(registry.activeId, created);
    });

    test('switchTo moves the pointer back', () async {
      final created = await registry.create();
      await registry.switchTo(legacyId);

      expect(registry.activeId, legacyId);
      expect(registry.ids, containsAll([legacyId, created]));
    });

    test('state persists across a reload', () async {
      final created = await registry.create();

      final reloaded = await ProfileRegistry.load(seedPatientId: 'ignored');
      expect(reloaded.count, 2);
      expect(reloaded.activeId, created);
      // The reloaded instance still knows which profile was migrated.
      expect(reloaded.legacyId, legacyId);
    });

    test('each profile gets its own archive file; the legacy mapping never '
        'moves', () async {
      final created = await registry.create();

      expect(registry.dbFileFor(legacyId), ProfileRegistry.legacyDbFile);
      expect(registry.dbFileFor(created), startsWith('mecai_readings_'));
      expect(
        registry.dbFileFor(created),
        isNot(registry.dbFileFor(legacyId)),
      );

      // Switching back must not re-record the legacy profile onto the derived
      // per-profile filename — that would orphan every reading it owns.
      await registry.switchTo(legacyId);
      expect(registry.dbFileFor(legacyId), ProfileRegistry.legacyDbFile);
    });

    test('switchTo ignores an unknown id', () async {
      await registry.switchTo('no-such-profile');

      expect(registry.activeId, legacyId);
    });
  });

  group('per-profile stores', () {
    test('ProfileStore reads through to the legacy layout until first save',
        () async {
      SharedPreferences.setMockInitialValues({
        'patient_id': legacyId,
        'profile_display_name': 'Maria Santos',
        'profile_age': 63,
        'profile_total_cholesterol_mgdl': 240.0,
        'profile_saved': true,
      });

      final profile = await ProfileStore.load(legacyId, legacyOf: legacyId);

      expect(profile.displayName, 'Maria Santos');
      expect(profile.profile.age, 63);
      expect(profile.profile.totalCholesterolMgdl, 240.0);
      expect(profile.hasBeenEdited, isTrue);

      // A save writes forward to the namespaced keys permanently — the value
      // no longer depends on the read-through rule.
      await profile.save(ProfileStore.empty.copyWith(age: 64));
      expect(profile.profile.age, 64);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('profile.$legacyId.age'), 64);
    });

    test('another profile sees none of the adopted profile\'s fields',
        () async {
      SharedPreferences.setMockInitialValues({
        'patient_id': legacyId,
        'profile_age': 63,
        'profile_saved': true,
      });
      final registry = await ProfileRegistry.load(seedPatientId: legacyId);
      final other = await registry.create();

      final profile = await ProfileStore.load(other);

      // Defaults, not the previous person's answers.
      expect(profile.profile.age, ProfileStore.empty.age);
      expect(profile.hasBeenEdited, isFalse);
    });

    test('EmergencyContacts are namespaced with legacy read-through',
        () async {
      SharedPreferences.setMockInitialValues({
        'patient_id': legacyId,
        'emergency_contacts':
            '[{"name":"Ana","phone":"09171234567","relationship":null}]',
      });
      final registry = await ProfileRegistry.load(seedPatientId: legacyId);
      final other = await registry.create();

      // The adopted profile by id — after create(), activeId is the new one.
      final adopted = await EmergencyContacts.load(legacyId, legacyOf: legacyId);
      expect(adopted.contacts.single.name, 'Ana');

      final fresh = await EmergencyContacts.load(other);
      expect(fresh.isEmpty, isTrue);

      // Editing the fresh profile must not touch the adopted person's list:
      // the write goes to the namespaced key.
      await fresh.add(const EmergencyContact(name: 'Ben', phone: '09180000000'));
      final reread = await EmergencyContacts.load(legacyId, legacyOf: legacyId);
      expect(reread.contacts.map((c) => c.name), ['Ana']);
    });
  });

  group('AppSettings.switchPatient', () {
    test('re-points identity without touching the stored preference',
        () async {
      SharedPreferences.setMockInitialValues({'patient_id': legacyId});
      final settings = await AppSettings.load();
      final next = '99999999-8888-7777-6666-555555555555';

      await settings.switchPatient(next);

      expect(settings.patientId, next);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('patient_id'), legacyId);
    });
  });
}

Future<String> _mintedId() async {
  final settings = await AppSettings.load();
  return settings.patientId;
}
