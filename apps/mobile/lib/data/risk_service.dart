/// Risk scoring client.
///
/// The scoring model lives in `services/api` and is not reimplemented here. A Dart
/// port of the Framingham coefficients would be a second source of truth for a
/// clinical calculation — the two would drift, and there would be no way to tell
/// which figure a user was shown. So the app calls the service, and shows an
/// explicit unreachable state when it cannot.
///
/// The base URL is read from [AppSettings] on every request rather than captured at
/// construction, so changing the address on the settings screen takes effect
/// immediately without rebuilding the service.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/vitals.dart';
import 'settings.dart';

class RiskServiceException implements Exception {
  RiskServiceException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'RiskServiceException: $message';
}

/// What `/health` reports — used by the settings screen's connection test.
class ApiHealth {
  const ApiHealth({
    required this.version,
    required this.riskModel,
    required this.mockEndpoints,
    this.storage = false,
    this.patients = 0,
    this.readings = 0,
  });

  final String version;
  final String riskModel;
  final bool mockEndpoints;

  /// Whether the server's readings archive is writable.
  ///
  /// Reported so the connection test proves the *whole* path rather than just
  /// that something answered. A server that scores but cannot store is a
  /// half-working state worth knowing about before relying on it for backup —
  /// not after a month of readings failed to arrive.
  final bool storage;

  final int patients;
  final int readings;

  factory ApiHealth.fromJson(Map<String, dynamic> json) => ApiHealth(
        version: json['version'] as String? ?? 'unknown',
        riskModel: json['risk_model'] as String? ?? 'unknown',
        mockEndpoints: json['mock_endpoints'] as bool? ?? false,
        storage: json['storage'] as bool? ?? false,
        patients: (json['patients'] as num?)?.toInt() ?? 0,
        readings: (json['readings'] as num?)?.toInt() ?? 0,
      );
}

class RiskService {
  RiskService({required AppSettings settings, http.Client? client})
      : _settings = settings,
        _client = client ?? http.Client();

  final AppSettings _settings;
  final http.Client _client;

  String get baseUrl => _settings.apiBaseUrl;

  /// Short timeout: this runs behind a button the user is watching.
  static const _healthTimeout = Duration(seconds: 5);
  static const _requestTimeout = Duration(seconds: 10);

  Future<ApiHealth> checkHealth() async {
    final body = await _get('/health', timeout: _healthTimeout);
    return ApiHealth.fromJson(body as Map<String, dynamic>);
  }

  Future<AssessmentResponse> assess({
    required RiskProfile profile,
    required VitalsReading reading,
  }) async {
    final body = await _post('/v1/assess', {
      'profile': profile.toJson(),
      'reading': reading.toJson(),
    });
    return AssessmentResponse.fromJson(body as Map<String, dynamic>);
  }

  Future<Object?> _get(String path, {Duration? timeout}) async {
    final url = '$baseUrl$path';
    final http.Response response;
    try {
      response = await _client.get(Uri.parse(url)).timeout(timeout ?? _requestTimeout);
    } on Exception catch (e) {
      throw RiskServiceException(_unreachable(e));
    }
    return _decode(response);
  }

  Future<Object?> _post(String path, Map<String, dynamic> payload) async {
    final url = '$baseUrl$path';
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(url),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_requestTimeout);
    } on Exception catch (e) {
      throw RiskServiceException(_unreachable(e));
    }
    return _decode(response);
  }

  Object? _decode(http.Response response) {
    if (response.statusCode != 200) {
      throw RiskServiceException(
        'Server returned ${response.statusCode}. ${_hint(response)}',
        statusCode: response.statusCode,
      );
    }
    return jsonDecode(response.body);
  }

  String _hint(http.Response response) => switch (response.statusCode) {
        404 => 'Endpoint not found — is this a MEC-AI server?',
        422 => 'The server rejected the reading as implausible.',
        >= 500 => 'The server hit an internal error. Check its log.',
        _ => response.body,
      };

  /// The failure users actually hit, with the two things they need to check.
  String _unreachable(Object error) =>
      "Can't reach the server at $baseUrl.\n\n"
      '• Confirm the address on this screen matches the computer running the API.\n'
      '• Start the API bound to your network, not just loopback:\n'
      '  uvicorn mecai_api.main:app --host 0.0.0.0 --port $defaultApiPort\n\n'
      '($error)';

  void dispose() => _client.close();
}
