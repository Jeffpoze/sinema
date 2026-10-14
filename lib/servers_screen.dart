import 'package:flutter/material.dart';

import 'main.dart';
import 'services/jellyfin_api_service.dart';
import 'services/server_store.dart';
import 'settings_controller.dart';
import 'widgets/server_logo.dart';

// Saved Jellyfin / Emby accounts. Tap one to switch to it; the whole app
// moves over to that server without signing in again.
class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key, required this.settings});
  final SettingsController settings;

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  final _store = ServerStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    _store.refreshServerInfo();
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _switchTo(JellyfinSession account) async {
    await _store.activate(account.accountId);
    if (mounted) goHome(context, widget.settings);
  }

  Future<void> _remove(JellyfinSession account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign Out of Server?'),
        content: Text('Sinema will forget ${account.displayName} (${account.username}). You can add it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Sign Out')),
        ],
      ),
    );
    if (confirmed != true) return;
    final wasActive = _store.active?.accountId == account.accountId;
    await _store.remove(account.accountId);
    if (!mounted) return;
    if (wasActive) {
      goHome(context, widget.settings);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _store.accounts;
    final activeId = _store.active?.accountId;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('SERVERS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
      body: ListView(
        children: [
          for (final account in accounts)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              leading: ServerLogo(session: account),
              title: Text(account.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${account.serverType.label} · ${account.username}\n${account.serverUrl}', style: const TextStyle(color: Color(0xFFA5A7AC), fontSize: 12)),
              isThreeLine: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (account.accountId == activeId) Icon(Icons.check_circle, color: accent),
                  PopupMenuButton<String>(
                    onSelected: (value) => value == 'remove' ? _remove(account) : _switchTo(account),
                    itemBuilder: (context) => [
                      if (account.accountId != activeId) const PopupMenuItem(value: 'switch', child: Text('Switch to this server')),
                      const PopupMenuItem(value: 'remove', child: Text('Sign out')),
                    ],
                  ),
                ],
              ),
              onTap: account.accountId == activeId ? null : () => _switchTo(account),
            ),
          if (accounts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No servers yet. Add your Jellyfin or Emby server to browse your library.', style: TextStyle(color: Color(0xFFA5A7AC))),
            ),
          const Divider(color: Color(0xFF1B1D22)),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Add Server'),
            subtitle: const Text('Jellyfin or Emby', style: TextStyle(color: Color(0xFFA5A7AC))),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AuthenticationScreen(settings: widget.settings))),
          ),
          ListTile(
            leading: const Icon(Icons.live_tv_rounded),
            title: const Text('Live TV Only'),
            subtitle: const Text('Use Sinema without a media server. Saved servers stay here.', style: TextStyle(color: Color(0xFFA5A7AC))),
            trailing: _store.startupMode == StartupMode.liveTvOnly ? Icon(Icons.check_circle, color: accent) : null,
            onTap: () async {
              await _store.useLiveTvOnly();
              if (context.mounted) goHome(context, widget.settings);
            },
          ),
        ],
      ),
    );
  }
}
