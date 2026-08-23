/// GPS for the SOS alert.
///
/// ### Never blocks the alert
///
/// Every method here returns a result rather than throwing, and every one has a
/// timeout. An SOS must fire whether or not a fix is available: indoors, in a
/// concrete building, or with location permission denied, `getCurrentPosition`
/// can hang for as long as the platform allows. Waiting on it would delay the
/// emergency itself, which inverts the priority — a responder can be told "location
/// unavailable" and still be told there is an emergency.
///
/// So the flow is: try for a fix within a short budget, fall back to the last known
/// position, and fall back again to no location at all.
library;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Where a position came from, so the UI never presents a stale fix as current.
enum FixQuality {
  /// Acquired now.
  live,

  /// The platform's last known position, from some earlier moment.
  lastKnown,

  /// No position available.
  none;

  String get label => switch (this) {
        FixQuality.live => 'Current location',
        FixQuality.lastKnown => 'Last known location',
        FixQuality.none => 'Location unavailable',
      };
}

@immutable
class LocationFix {
  const LocationFix({
    this.latitude,
    this.longitude,
    this.accuracyM,
    this.timestamp,
    required this.quality,
    this.problem,
  });

  const LocationFix.unavailable({this.problem})
      : latitude = null,
        longitude = null,
        accuracyM = null,
        timestamp = null,
        quality = FixQuality.none;

  final double? latitude;
  final double? longitude;
  final double? accuracyM;
  final DateTime? timestamp;
  final FixQuality quality;

  /// Why there is no fix, in words the user can act on ("Location is switched
  /// off", "Permission denied") rather than an exception string.
  final String? problem;

  bool get hasPosition => latitude != null && longitude != null;

  /// A link any responder can open, in any messaging app, on any phone.
  ///
  /// `google.com/maps/search/?api=1&query=lat,lon` rather than a geo: URI: a geo:
  /// link only resolves on a device with a maps app registered for the scheme, and
  /// an SMS may well be read on a desktop or a feature phone. An https link always
  /// opens something.
  String? get mapsUrl => hasPosition
      ? 'https://www.google.com/maps/search/?api=1&query='
          '${latitude!.toStringAsFixed(6)},${longitude!.toStringAsFixed(6)}'
      : null;

  /// Coordinates in the conventional order, for a reader without a link.
  String get coordinatesLabel => hasPosition
      ? '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}'
      : '—';
}

class LocationService {
  /// Budget for a live fix during an SOS.
  ///
  /// Eight seconds: long enough for a warm GPS or a network fix, short enough that
  /// the alert is not held up. The last-known fallback covers the rest.
  static const Duration sosTimeout = Duration(seconds: 8);

  /// Asks for permission, reporting the outcome rather than throwing.
  ///
  /// Called from the settings screen so the prompt appears while the user is
  /// calmly setting the feature up — not for the first time mid-emergency, when a
  /// permission dialog is standing between them and an ambulance.
  Future<bool> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } on Object catch (error) {
      debugPrint('LocationService: permission check failed. $error');
      return false;
    }
  }

  /// Best position available within [sosTimeout]. Never throws.
  Future<LocationFix> currentFix({Duration? timeout}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationFix.unavailable(
          problem: 'Location is switched off on this phone.',
        );
      }

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return const LocationFix.unavailable(
          problem: 'This app does not have permission to use your location.',
        );
      }

      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: timeout ?? sosTimeout,
          ),
        );
        return _fix(position, FixQuality.live);
      } on Object {
        // Timed out or no signal. A stale position labelled as stale beats none.
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return _fix(last, FixQuality.lastKnown);
        return const LocationFix.unavailable(
          problem: 'No GPS fix yet. Move somewhere with a clearer view of the sky.',
        );
      }
    } on Object catch (error) {
      debugPrint('LocationService: fix failed. $error');
      return LocationFix.unavailable(problem: 'Could not read location. $error');
    }
  }

  static LocationFix _fix(Position position, FixQuality quality) => LocationFix(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyM: position.accuracy,
        timestamp: position.timestamp,
        quality: quality,
      );
}
