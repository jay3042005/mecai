/// Emergency contacts the SOS SMS is sent to.
///
/// Stored on the device, never uploaded. A contact list is other people's personal
/// data — the user consented to sharing their own health readings with the service,
/// not their family's phone numbers, and RA 10173 treats those as personal
/// information belonging to the contact rather than to the user.
///
/// ### Ordering matters
///
/// The first contact is the primary. When the SOS fires, that is who the composer
/// opens to. Responders are not interchangeable — "my daughter who lives nearby"
/// and "my doctor's clinic" want different priority, and the user is the one who
/// knows which.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class EmergencyContact {
  const EmergencyContact({
    required this.name,
    required this.phone,
    this.relationship,
  });

  final String name;

  /// As the user typed it, normalised by [EmergencyContacts.normalizePhone].
  final String phone;

  final String? relationship;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'phone': phone,
        'relationship': relationship,
      };

  static EmergencyContact fromJson(Map<String, dynamic> json) => EmergencyContact(
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        relationship: json['relationship'] as String?,
      );

  EmergencyContact copyWith({String? name, String? phone, String? relationship}) =>
      EmergencyContact(
        name: name ?? this.name,
        phone: phone ?? this.phone,
        relationship: relationship ?? this.relationship,
      );
}

class EmergencyContacts extends ChangeNotifier {
  EmergencyContacts._(this._prefs, this._contacts, {required String? id})
      : _key = id == null ? _legacyKey : 'emergency_contacts.$id';

  static const _legacyKey = 'emergency_contacts';

  /// The key this instance reads and writes.
  ///
  /// Namespaced per profile when one was given at [load] — a shared phone keeps
  /// each person's responders separate, because "call my daughter" means a
  /// different person depending on whose SOS it is.
  final String _key;

  /// Guardrail on the contact list.
  ///
  /// More numbers is not more safety — an SOS that opens seven composers in
  /// sequence is an SOS nobody finishes sending.
  static const int maxContacts = 5;

  final SharedPreferences? _prefs;
  List<EmergencyContact> _contacts;

  /// In priority order. The first is who the SOS opens to.
  List<EmergencyContact> get contacts => List.unmodifiable(_contacts);

  bool get isEmpty => _contacts.isEmpty;

  bool get isPersistent => _prefs != null;

  EmergencyContact? get primary => _contacts.isEmpty ? null : _contacts.first;

  /// Loads the contact list for [id], or the legacy un-namespaced list when
  /// null.
  ///
  /// [legacyOf] lets the profile adopted from a single-profile install keep
  /// reading its old list until the user edits it — the first write moves the
  /// data to the namespaced key for good.
  static Future<EmergencyContacts> load(String? id, {String? legacyOf}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var raw = prefs.getString(_instanceKey(id));
      if (raw == null && id != null && id == legacyOf) {
        raw = prefs.getString(_legacyKey);
      }
      final contacts = <EmergencyContact>[];
      if (raw != null) {
        for (final entry in jsonDecode(raw) as List<dynamic>) {
          contacts.add(EmergencyContact.fromJson(entry as Map<String, dynamic>));
        }
      }
      return EmergencyContacts._(prefs, contacts, id: id);
    } on Object catch (error) {
      // The SOS button must still work with an unusable preferences store.
      debugPrint('EmergencyContacts: store unavailable. $error');
      return EmergencyContacts._(null, <EmergencyContact>[], id: id);
    }
  }

  static String _instanceKey(String? id) =>
      id == null ? _legacyKey : 'emergency_contacts.$id';

  Future<void> _persist() async {
    await _prefs?.setString(
      _key,
      jsonEncode([for (final contact in _contacts) contact.toJson()]),
    );
    notifyListeners();
  }

  Future<void> add(EmergencyContact contact) async {
    if (_contacts.length >= maxContacts) return;
    _contacts = [..._contacts, contact];
    await _persist();
  }

  Future<void> replaceAt(int index, EmergencyContact contact) async {
    if (index < 0 || index >= _contacts.length) return;
    final next = [..._contacts];
    next[index] = contact;
    _contacts = next;
    await _persist();
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _contacts.length) return;
    final next = [..._contacts]..removeAt(index);
    _contacts = next;
    await _persist();
  }

  /// Moves a contact to the front, making it the one the SOS opens to.
  Future<void> makePrimary(int index) async {
    if (index <= 0 || index >= _contacts.length) return;
    final next = [..._contacts];
    final contact = next.removeAt(index);
    _contacts = [contact, ...next];
    await _persist();
  }

  /// Strips formatting so the number reaches the dialler intact.
  ///
  /// Spaces, dashes and brackets are how people write numbers and are not part of
  /// them; a leading `+` is. Philippine mobile numbers are commonly written
  /// `0917 123 4567` or `+63 917 123 4567`, and both must dial.
  static String normalizePhone(String raw) {
    final trimmed = raw.trim();
    final buffer = StringBuffer();
    for (var i = 0; i < trimmed.length; i++) {
      final char = trimmed[i];
      if (char == '+' && i == 0) {
        buffer.write(char);
      } else if (char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39) {
        buffer.write(char);
      }
    }
    return buffer.toString();
  }

  /// Whether [raw] could plausibly be dialled.
  ///
  /// Deliberately permissive: this runs on the screen where someone enters the
  /// number that will be used in an emergency, and rejecting a valid but
  /// unusually-formatted number is a worse failure than accepting a typo. Short
  /// A three-digit minimum keeps short codes valid without accepting a stray digit.
  static bool isPlausiblePhone(String raw) {
    final digits = normalizePhone(raw).replaceAll('+', '');
    return digits.length >= 3 && digits.length <= 15;
  }
}
