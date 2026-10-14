import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'jellyfin_api_service.dart';

// What the app should open into.
enum StartupMode { welcome, server, liveTvOnly }

// Every Jellyfin / Emby account signed into on this device, and which one is
// active. Only one server is in use at a time; switching swaps the home
// screen over to another saved account without signing in again.
class ServerStore {
  ServerStore._();
  static final instance = ServerStore._();

  static const _accountsKey = 'servers.accounts';
  static const _activeKey = 'servers.active';
  static const _liveTvOnlyKey = 'servers.liveTvOnly';

  List<JellyfinSession> _accounts = [];
  String? _activeId;
  bool _liveTvOnly = false;

  List<JellyfinSession> get accounts => List.unmodifiable(_accounts);
  bool get liveTvOnly => _liveTvOnly;

  JellyfinSession? get active {
    for (final a in _accounts) {
      if (a.accountId == _activeId) return a;
    }
    return null;
  }

  StartupMode get startupMode {
    if (active != null) return StartupMode.server;
    if (_liveTvOnly) return StartupMode.liveTvOnly;
    return StartupMode.welcome;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_accountsKey);
    if (raw != null) {
      try {
        _accounts = [for (final j in jsonDecode(raw) as List<dynamic>) JellyfinSession.fromJson(j as Map<String, dynamic>)];
      } catch (_) {
        _accounts = [];
      }
    }
    _activeId = prefs.getString(_activeKey);
    _liveTvOnly = prefs.getBool(_liveTvOnlyKey) ?? false;

    // Carry over the single sign-in older versions of the app saved.
    final legacyUrl = prefs.getString('serverUrl');
    final legacyUser = prefs.getString('userId');
    final legacyToken = prefs.getString('accessToken');
    if (legacyUrl != null && legacyUser != null && legacyToken != null) {
      final legacy = JellyfinSession(
        serverUrl: legacyUrl,
        userId: legacyUser,
        token: legacyToken,
        username: prefs.getString('username') ?? '',
      );
      if (!_accounts.any((a) => a.accountId == legacy.accountId)) _accounts.add(legacy);
      _activeId ??= legacy.accountId;
      for (final key in ['serverUrl', 'userId', 'accessToken', 'username']) {
        await prefs.remove(key);
      }
      await _save();
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accountsKey, jsonEncode([for (final a in _accounts) a.toJson()]));
    if (_activeId == null) {
      await prefs.remove(_activeKey);
    } else {
      await prefs.setString(_activeKey, _activeId!);
    }
    await prefs.setBool(_liveTvOnlyKey, _liveTvOnly);
  }

  // Adds (or refreshes the token of) an account and makes it active.
  Future<void> addAndActivate(JellyfinSession session, {bool remember = true}) async {
    _accounts = [for (final a in _accounts) if (a.accountId != session.accountId) a, session];
    _activeId = session.accountId;
    _liveTvOnly = false;
    if (remember) {
      await _save();
    } else {
      // Not remembered: usable for this run only, gone on next launch.
      final saved = _accounts.where((a) => a.accountId != session.accountId).toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_accountsKey, jsonEncode([for (final a in saved) a.toJson()]));
      await prefs.remove(_activeKey);
    }
  }

  Future<void> activate(String accountId) async {
    _activeId = accountId;
    _liveTvOnly = false;
    await _save();
  }

  Future<void> remove(String accountId) async {
    _accounts = _accounts.where((a) => a.accountId != accountId).toList();
    if (_activeId == accountId) _activeId = _accounts.isEmpty ? null : _accounts.first.accountId;
    await _save();
  }

  // Use the app for Live TV only; saved servers stay available to switch to.
  Future<void> useLiveTvOnly() async {
    _activeId = null;
    _liveTvOnly = true;
    await _save();
  }
}
