/// Whether the scoring server is answering, as live chrome can show it.
///
/// The header needed a truth source for its connection dot that did not depend
/// on side effects: [MonitorController.serverError] only updates after a score
/// attempt, which may be minutes stale or never fire on a quiet wrist. This
/// probes `/health` directly — cheap, honest, and on a cadence.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'risk_service.dart';
import 'settings.dart';

enum ServerLink { checking, online, offline }

class ServerStatus extends ChangeNotifier {
  ServerStatus(this._risk, this._settings);

  final RiskService _risk;
  final AppSettings _settings;

  ServerLink _link = ServerLink.checking;
  String? _address;

  ServerLink get link => _link;

  /// The base URL the last successful probe used — null while offline, since
  /// the configured address is exactly what failed.
  String? get address => _link == ServerLink.online ? _address : null;

  /// Address being probed right now, so the sheet can show what is configured
  /// even while it is not answering.
  String get configuredAddress => _settings.apiBaseUrl;

  Timer? _timer;

  void start({Duration every = const Duration(seconds: 30)}) {
    unawaited(probe());
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => probe());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// One health round-trip against the configured address.
  Future<void> probe() async {
    try {
      await _risk.checkHealth();
      _address = _settings.apiBaseUrl;
      _set(ServerLink.online);
    } on RiskServiceException {
      _set(ServerLink.offline);
    } catch (error) {
      // A programming error must not take down the indicator loop.
      debugPrint('ServerStatus: probe crashed. $error');
      _set(ServerLink.offline);
    }
  }

  void _set(ServerLink next) {
    if (_link == next) return;
    _link = next;
    notifyListeners();
  }
}
