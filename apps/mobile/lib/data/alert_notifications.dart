import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/vitals.dart';

/// Local alert channel for acute findings. This is deliberately separate from
/// the in-app popup: Android can surface the same warning while another tab or
/// another app is in front.
class AlertNotifications {
  AlertNotifications._();

  static final plugin = FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(
      settings: const InitializationSettings(android: android),
    );
    await plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> show(AcuteFlag flag) async {
    final android = AndroidNotificationDetails(
      'mecai_alerts',
      'MEC-AI alerts',
      channelDescription: 'Immediate alerts from watch vitals',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      ticker: 'MEC-AI alert',
    );
    await plugin.show(
      id: flag.severity == Severity.critical ? 1001 : 1000,
      title: '${flag.vital} ${flag.displayValue}',
      body: flag.message,
      notificationDetails: NotificationDetails(android: android),
    );
  }
}
