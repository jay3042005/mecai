/// BLE transport for the MEC-AI watch.
///
/// Implements [VitalsSource] by connecting to the ESP32-S3 "MECAI-Watch" over
/// Bluetooth Low Energy. The watch runs a GATT server (see MEC-AI3.ino) that
/// exposes a vitals characteristic notifying at 2 Hz with a 12-byte packed
/// struct, an SOS characteristic, and a command write point.
///
/// Byte layout of the vitals packet (little-endian):
///   [0-1]  uint16  heartRate   (BPM × 10, 0 = invalid)
///   [2-3]  uint16  spo2        (% × 10, 0 = invalid)
///   [4-5]  int16   ambientTemp (°C × 100)
///   [6]    uint8   wearing     (0 or 1)
///   [7]    uint8   sosActive   (0 or 1)
///   [8]    uint8   displayMode
///   [9]    uint8   useFahrenheit (0 or 1)
///   [10-11] uint16 reserved
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/vitals.dart';
import 'vitals_source.dart';

/// Custom UUIDs matching MEC-AI3.ino.
const String _mecaiServiceUuid  = '4d454341-4920-4845-414c-544800000001';
const String _vitalsCharUuid    = '4d454341-4920-4845-414c-544800000010';
const String _sosCharUuid       = '4d454341-4920-4845-414c-544800000020';
const String _commandCharUuid   = '4d454341-4920-4845-414c-544800000030';

const String mecaiDeviceName = 'MECAI-Watch';

/// BLE commands the phone can send to the watch.
class WatchCommand {
  WatchCommand._();
  static const int toggleSos     = 0x01;
  static const int toggleTempUnit = 0x02;
  static const int cycleDisplay   = 0x03;
}

/// Parsed vitals from the 12-byte BLE packet.
@immutable
class WatchVitals {
  const WatchVitals({
    required this.heartRateBpm,
    required this.spo2Pct,
    required this.ambientTempC,
    required this.wearing,
    required this.sosActive,
    required this.displayMode,
    required this.useFahrenheit,
  });

  final double? heartRateBpm;
  final double? spo2Pct;
  final double? ambientTempC;
  final bool wearing;
  final bool sosActive;
  final int displayMode;
  final bool useFahrenheit;

  /// Decode the 12-byte packed struct from the ESP32.
  factory WatchVitals.fromBytes(List<int> bytes) {
    if (bytes.length < 12) {
      return const WatchVitals(
        heartRateBpm: null,
        spo2Pct: null,
        ambientTempC: null,
        wearing: false,
        sosActive: false,
        displayMode: 0,
        useFahrenheit: false,
      );
    }

    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final rawHr = data.getUint16(0, Endian.little);
    final rawSpo2 = data.getUint16(2, Endian.little);
    final rawTemp = data.getInt16(4, Endian.little);

    return WatchVitals(
      heartRateBpm: rawHr > 0 ? rawHr / 10.0 : null,
      spo2Pct: rawSpo2 > 0 ? rawSpo2 / 10.0 : null,
      ambientTempC: rawTemp != 0 ? rawTemp / 100.0 : null,
      wearing: bytes[6] != 0,
      sosActive: bytes[7] != 0,
      displayMode: bytes[8],
      useFahrenheit: bytes[9] != 0,
    );
  }
}

/// Real BLE source that connects to the MECAI-Watch.
class BleVitalsSource implements VitalsSource {
  BleVitalsSource();

  final StreamController<LinkState> _linkController =
      StreamController<LinkState>.broadcast();
  LinkState _state = LinkState.disconnected;

  BluetoothDevice? _device;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  StreamSubscription<List<int>>? _vitalsSub;
  StreamSubscription<List<int>>? _sosSub;
  BluetoothCharacteristic? _commandChar;

  WatchVitals? _latestVitals;
  final List<VitalsReading> _readings = [];
  VitalsReading? _last;
  DateTime _lastStoredAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _reconnectTimer;
  bool _isConnectingOrScanning = false;

  /// Stream of parsed vitals from the watch, for UI to listen to.
  final StreamController<WatchVitals> _vitalsController =
      StreamController<WatchVitals>.broadcast();
  Stream<WatchVitals> get watchVitals => _vitalsController.stream;
  WatchVitals? get latestWatchVitals => _latestVitals;

  /// Stream of SOS state changes from the watch.
  final StreamController<bool> _sosController =
      StreamController<bool>.broadcast();
  Stream<bool> get sosStream => _sosController.stream;

  @override
  Stream<LinkState> get linkState => _linkController.stream;

  @override
  LinkState get currentLinkState => _state;

  @override
  VitalsReading? get lastReading => _last;

  void _setState(LinkState s) {
    if (_state == s) return;
    _state = s;
    if (!_linkController.isClosed) _linkController.add(s);
  }

  /// Scan for and connect to the MECAI-Watch with background resilience.
  @override
  Future<void> connect() async {
    if (_state == LinkState.connected || _state == LinkState.streaming) {
      return;
    }
    if (_isConnectingOrScanning) return;

    _reconnectTimer?.cancel();
    _isConnectingOrScanning = true;
    _setState(LinkState.scanning);

    try {
      // 1. Stop any dangling scan first to avoid Android scan errors
      if (FlutterBluePlus.isScanningNow) {
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
      }

      // 2. Check if already connected via system Bluetooth
      try {
        final connected = FlutterBluePlus.connectedDevices;
        for (final d in connected) {
          final name = (d.advName.isNotEmpty ? d.advName : d.platformName).toLowerCase();
          if (name.contains('mecai') || name.contains('mec-ai')) {
            _device = d;
            _setState(LinkState.connecting);
            await _setupDevice(d);
            _isConnectingOrScanning = false;
            return;
          }
        }
      } catch (e) {
        debugPrint('BleVitalsSource connectedDevices check note: $e');
      }

      // 3. Scan for MECAI-Watch with name and UUID heuristics
      final completer = Completer<BluetoothDevice?>();
      StreamSubscription<List<ScanResult>>? scanSub;

      scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final advName = (r.device.advName.isNotEmpty
                  ? r.device.advName
                  : r.advertisementData.advName.isNotEmpty
                      ? r.advertisementData.advName
                      : r.device.platformName)
              .toLowerCase();

          final hasMecService = r.advertisementData.serviceUuids.any(
            (u) => u.toString().toLowerCase().contains('4d454341'),
          );

          if (advName.contains('mecai') || advName.contains('mec-ai') || hasMecService) {
            if (!completer.isCompleted) {
              completer.complete(r.device);
            }
            scanSub?.cancel();
            FlutterBluePlus.stopScan();
            break;
          }
        }
      });

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        androidUsesFineLocation: false,
      );

      final foundDevice = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );

      scanSub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}

      if (foundDevice != null) {
        _device = foundDevice;
        _setState(LinkState.connecting);
        await _setupDevice(foundDevice);
      } else {
        _setState(LinkState.disconnected);
        _scheduleAutoReconnect();
      }
    } catch (e) {
      debugPrint('BleVitalsSource connect error: $e');
      _setState(LinkState.disconnected);
      _scheduleAutoReconnect();
    } finally {
      _isConnectingOrScanning = false;
    }
  }

  void _scheduleAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (_state == LinkState.disconnected && !_isConnectingOrScanning) {
        debugPrint('BleVitalsSource: attempting background auto-reconnect to $mecaiDeviceName');
        connect();
      }
    });
  }

  Future<void> _setupDevice(BluetoothDevice device) async {
    // Listen for disconnection and background reconnection
    _connectionSub?.cancel();
    _connectionSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _onDisconnected();
      } else if (state == BluetoothConnectionState.connected && _vitalsSub == null) {
        _bindServices(device);
      }
    });

    // Connect with standard BLE parameters
    if ((await device.connectionState.first) !=
        BluetoothConnectionState.connected) {
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
        mtu: null,
      );
    }

    await _bindServices(device);
  }

  Future<void> _bindServices(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      BluetoothService? mecaiService;
      for (final s in services) {
        if (s.uuid.toString().toLowerCase() == _mecaiServiceUuid) {
          mecaiService = s;
          break;
        }
      }

      if (mecaiService == null) {
        await device.disconnect();
        _setState(LinkState.disconnected);
        throw Exception('MECAI service not found on device');
      }

      // Find characteristics
      for (final c in mecaiService.characteristics) {
        final uuid = c.uuid.toString().toLowerCase();
        if (uuid == _vitalsCharUuid) {
          await c.setNotifyValue(true);
          _vitalsSub?.cancel();
          _vitalsSub = c.onValueReceived.listen(_onVitalsData);
        } else if (uuid == _sosCharUuid) {
          await c.setNotifyValue(true);
          _sosSub?.cancel();
          _sosSub = c.onValueReceived.listen(_onSOSData);
        } else if (uuid == _commandCharUuid) {
          _commandChar = c;
        }
      }

      _setState(LinkState.connected);
      debugPrint('BleVitalsSource: connected to $mecaiDeviceName');
    } catch (e) {
      debugPrint('BleVitalsSource _bindServices error: $e');
    }
  }

  void _onVitalsData(List<int> value) {
    final vitals = WatchVitals.fromBytes(value);
    _latestVitals = vitals;
    if (!_vitalsController.isClosed) _vitalsController.add(vitals);

    // Promote to streaming state on first data reception
    if (_state == LinkState.connected) {
      _setState(LinkState.streaming);
    }

    // Always update the latest reading for immediate UI access
    _last = VitalsReading(
      heartRateBpm: vitals.heartRateBpm,
      spo2Pct: vitals.spo2Pct,
      ambientTempC: vitals.ambientTempC,
      measuredAt: DateTime.now(),
    );

    // Store to history at most every 10 seconds to avoid flooding memory.
    // Real-time UI reads _last directly; history is for trends and backup.
    final now = DateTime.now();
    if (now.difference(_lastStoredAt).inSeconds >= 10) {
      _lastStoredAt = now;
      _readings.add(_last!);

      // Keep only last 24h of readings
      final cutoff = now.subtract(const Duration(hours: 24));
      _readings.removeWhere((r) => r.measuredAt.isBefore(cutoff));
    }
  }

  void _onSOSData(List<int> value) {
    if (value.isNotEmpty) {
      final active = value[0] != 0;
      if (!_sosController.isClosed) _sosController.add(active);
    }
  }

  void _onDisconnected() {
    _vitalsSub?.cancel();
    _sosSub?.cancel();
    _vitalsSub = null;
    _sosSub = null;
    _commandChar = null;
    _setState(LinkState.disconnected);
    debugPrint('BleVitalsSource: disconnected from $mecaiDeviceName');
    _scheduleAutoReconnect();
  }

  /// Send a command byte to the watch.
  Future<void> sendCommand(int command) async {
    if (_commandChar == null || _state != LinkState.connected) return;
    await _commandChar!.write([command], withoutResponse: false);
  }

  @override
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    await _device?.disconnect();
    _onDisconnected();
  }

  /// Not applicable for continuous BLE streaming — returns immediately with the
  /// latest reading wrapped in the done phase.
  @override
  Stream<MeasureProgress> measure() async* {
    yield const MeasureProgress(
      phase: MeasurePhase.prepare,
      cuffPressureMmHg: 0,
      targetPressureMmHg: 0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // For BLE streaming, the watch sends data continuously.
    // We just package the latest reading as "done".
    yield const MeasureProgress(
      phase: MeasurePhase.done,
      cuffPressureMmHg: 0,
      targetPressureMmHg: 0,
    );
  }

  @override
  Future<List<VitalsReading>> history({
    Duration window = const Duration(hours: 24),
  }) async {
    final cutoff = DateTime.now().subtract(window);
    return _readings
        .where((r) => r.measuredAt.isAfter(cutoff))
        .toList(growable: false);
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _connectionSub?.cancel();
    _vitalsSub?.cancel();
    _sosSub?.cancel();
    _linkController.close();
    _vitalsController.close();
    _sosController.close();
    _device?.disconnect();
  }
}
