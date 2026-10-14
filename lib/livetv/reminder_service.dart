import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'iptv_models.dart';

// "Remind me" for upcoming programmes, as in TiviMate: a local notification
// a couple of minutes before the show starts. Reminders are kept in prefs so
// the bell icons survive restarts; expired ones are pruned on load.
class ReminderService extends ChangeNotifier {
  ReminderService._();
  static final instance = ReminderService._();

  static const _key = 'iptv.reminders';
  static const _lead = Duration(minutes: 2);

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  final Map<String, _Reminder> _reminders = {};

  // Called when a reminder notification is tapped, with the channel id.
  void Function(String channelId)? onOpenChannel;

  static String keyFor(IptvItem channel, EpgProgram program) => '${channel.id}@${program.start.millisecondsSinceEpoch}';

  bool has(IptvItem channel, EpgProgram program) => _reminders.containsKey(keyFor(channel, program));

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Ask for permission only when the first reminder is set.
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestSoundPermission: false, requestBadgePermission: false),
      ),
      onDidReceiveNotificationResponse: (response) {
        final channelId = response.payload;
        if (channelId != null && channelId.isNotEmpty) onOpenChannel?.call(channelId);
      },
    );
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final now = DateTime.now();
        (jsonDecode(raw) as Map<String, dynamic>).forEach((key, value) {
          final r = _Reminder.fromJson(value as Map<String, dynamic>);
          if (r.start.isAfter(now)) _reminders[key] = r;
        });
      } catch (_) {}
    }
    // A notification that launched the app.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final payload = launch?.notificationResponse?.payload;
    if ((launch?.didNotificationLaunchApp ?? false) && payload != null && payload.isNotEmpty) {
      Future<void>.delayed(const Duration(milliseconds: 600), () => onOpenChannel?.call(payload));
    }
    notifyListeners();
  }

  Future<bool> _ensurePermission() async {
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) return await ios.requestPermissions(alert: true, sound: true, badge: false) ?? false;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) return await android.requestNotificationsPermission() ?? true;
    return true;
  }

  // Returns false if notifications aren't allowed.
  Future<bool> toggle(IptvItem channel, EpgProgram program) async {
    await init();
    final key = keyFor(channel, program);
    final existing = _reminders.remove(key);
    if (existing != null) {
      await _plugin.cancel(id: existing.id);
      notifyListeners();
      await _save();
      return true;
    }
    if (!await _ensurePermission()) return false;
    final id = key.hashCode & 0x7fffffff;
    var at = program.start.subtract(_lead);
    if (!at.isAfter(DateTime.now())) at = DateTime.now().add(const Duration(seconds: 5));
    await _plugin.zonedSchedule(
      id: id,
      scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('program_reminders', 'Program reminders', channelDescription: 'Live TV shows you asked to be reminded about', importance: Importance.high, priority: Priority.high),
        iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      ),
      // Inexact keeps it permission-free on Android; a minute either way is fine.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      title: '${program.title} starts soon',
      body: 'On ${channel.name} at ${_hhmm(program.start)}. Tap to watch.',
      payload: channel.id,
    );
    _reminders[key] = _Reminder(id: id, start: program.start, title: program.title, channelName: channel.name);
    notifyListeners();
    await _save();
    return true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode({for (final e in _reminders.entries) e.key: e.value.toJson()}));
  }

  static String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _Reminder {
  const _Reminder({required this.id, required this.start, required this.title, required this.channelName});
  final int id;
  final DateTime start;
  final String title;
  final String channelName;

  Map<String, dynamic> toJson() => {'id': id, 'start': start.millisecondsSinceEpoch, 'title': title, 'channel': channelName};

  static _Reminder fromJson(Map<String, dynamic> j) => _Reminder(
        id: (j['id'] as num).toInt(),
        start: DateTime.fromMillisecondsSinceEpoch((j['start'] as num).toInt()),
        title: (j['title'] as String?) ?? '',
        channelName: (j['channel'] as String?) ?? '',
      );
}
