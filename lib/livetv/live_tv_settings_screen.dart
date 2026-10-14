import 'package:flutter/material.dart';

import 'iptv_repository.dart';
import 'live_tv_screen.dart' show askPin;

const _muted = Color(0xFFA5A7AC);

class LiveTvSettingsScreen extends StatefulWidget {
  const LiveTvSettingsScreen({super.key, this.focusPin = false});
  // Opened from "Lock group" before a PIN exists: go straight to PIN setup.
  final bool focusPin;

  @override
  State<LiveTvSettingsScreen> createState() => _LiveTvSettingsScreenState();
}

class _LiveTvSettingsScreenState extends State<LiveTvSettingsScreen> {
  final _repo = IptvRepository.instance;

  @override
  void initState() {
    super.initState();
    if (widget.focusPin) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _setPin());
    }
  }

  Future<String?> _promptNewPin() async {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('Set Parental PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Locked groups ask for this PIN before playing.', style: TextStyle(color: _muted)),
              const SizedBox(height: 12),
              TextField(controller: first, autofocus: true, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: const InputDecoration(labelText: 'New PIN', counterText: '')),
              const SizedBox(height: 10),
              TextField(controller: second, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: InputDecoration(labelText: 'Confirm PIN', counterText: '', errorText: error)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (first.text.length < 4) {
                  setState(() => error = 'Use at least 4 digits');
                } else if (first.text != second.text) {
                  setState(() => error = 'The PINs don\'t match');
                } else {
                  Navigator.of(dialogContext).pop(first.text);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setPin() async {
    if (_repo.hasPin && !await askPin(context, title: 'Current PIN')) return;
    final pin = await _promptNewPin();
    if (pin == null) return;
    await _repo.updatePrefs((p) => p.copyWith(pin: pin));
    _repo.unlock(pin);
  }

  Future<void> _removePin() async {
    if (!await askPin(context, title: 'Current PIN')) return;
    await _repo.updatePrefs((p) => p.copyWith(pin: '', lockedGroups: {}));
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 6),
        child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: _muted)),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('LIVE TV SETTINGS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
        body: AnimatedBuilder(
          animation: _repo,
          builder: (context, _) {
            final prefs = _repo.prefs;
            return ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _header('Channels'),
                ListTile(
                  title: const Text('Sort Channels'),
                  trailing: DropdownButton<ChannelSort>(
                    value: prefs.sort,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: ChannelSort.playlist, child: Text('Playlist order')),
                      DropdownMenuItem(value: ChannelSort.number, child: Text('Channel number')),
                      DropdownMenuItem(value: ChannelSort.name, child: Text('Name')),
                    ],
                    onChanged: (v) => v == null ? null : _repo.updatePrefs((p) => p.copyWith(sort: v)),
                  ),
                ),
                SwitchListTile(
                  title: const Text('Start with Last Channel'),
                  subtitle: const Text('Opening Live TV plays the channel you watched last.', style: TextStyle(color: _muted)),
                  value: prefs.autoPlayLast,
                  onChanged: (v) => _repo.updatePrefs((p) => p.copyWith(autoPlayLast: v)),
                ),
                ListTile(
                  title: const Text('Manage Groups'),
                  subtitle: const Text('Reorder, hide or lock channel groups', style: TextStyle(color: _muted)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _GroupManagerScreen())),
                ),
                ListTile(
                  title: const Text('Hidden Channels'),
                  subtitle: Text('${prefs.hiddenChannels.length} hidden', style: const TextStyle(color: _muted)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _HiddenChannelsScreen())),
                ),
                ListTile(
                  title: const Text('Clear Recently Watched'),
                  onTap: () => _repo.clearRecents(),
                ),
                _header('Parental Control'),
                ListTile(
                  title: Text(_repo.hasPin ? 'Change PIN' : 'Set PIN'),
                  subtitle: Text(
                    _repo.hasPin ? '${prefs.lockedGroups.length} locked group${prefs.lockedGroups.length == 1 ? '' : 's'}' : 'Lock groups like adult channels behind a PIN',
                    style: const TextStyle(color: _muted),
                  ),
                  onTap: _setPin,
                ),
                if (_repo.hasPin) ...[
                  ListTile(
                    title: Text(_repo.parentalUnlocked ? 'Lock Now' : 'Locked'),
                    subtitle: const Text('Locked groups unlock with the PIN until the app closes.', style: TextStyle(color: _muted)),
                    onTap: _repo.parentalUnlocked ? _repo.relock : null,
                  ),
                  ListTile(title: const Text('Remove PIN'), onTap: _removePin),
                ],
                _header('Guide'),
                ListTile(
                  title: const Text('Refresh Guide Now'),
                  subtitle: const Text('Guides refresh on their own every 12 hours.', style: TextStyle(color: _muted)),
                  onTap: () {
                    for (final s in _repo.sources) {
                      _repo.refreshEpg(s.id);
                    }
                  },
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text('Guide times off by an hour or more? Set a time offset on the playlist under Playlists.', style: TextStyle(color: _muted, fontSize: 12)),
                ),
              ],
            );
          },
        ),
      );
}

class _GroupManagerScreen extends StatelessWidget {
  const _GroupManagerScreen();

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('GROUPS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
      body: AnimatedBuilder(
        animation: repo,
        builder: (context, _) {
          final prefs = repo.prefs;
          // Visible groups in their display order, then hidden ones.
          final visible = repo.liveGroups;
          final hidden = repo.allLiveGroups.where((g) => prefs.hiddenGroups.contains(g)).toList();
          final groups = [...visible, ...hidden];
          final accent = Theme.of(context).colorScheme.primary;
          return ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: 32),
            header: const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Text('Drag to reorder. Tap the eye to hide a group, the lock to protect it with your PIN.', style: TextStyle(color: _muted)),
            ),
            itemCount: groups.length,
            onReorder: (oldIndex, newIndex) {
              final order = [...groups];
              if (newIndex > oldIndex) newIndex -= 1;
              order.insert(newIndex, order.removeAt(oldIndex));
              repo.updatePrefs((p) => p.copyWith(groupOrder: order));
            },
            itemBuilder: (context, index) {
              final group = groups[index];
              final isHidden = prefs.hiddenGroups.contains(group);
              final isLocked = prefs.lockedGroups.contains(group);
              final count = repo.allLiveChannels.where((c) => c.group == group).length;
              return ListTile(
                key: ValueKey(group),
                title: Text(group, style: TextStyle(color: isHidden ? _muted : Colors.white)),
                subtitle: Text('$count channels', style: const TextStyle(color: _muted, fontSize: 12)),
                leading: const Icon(Icons.drag_handle, color: _muted),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: isLocked ? 'Unlock' : 'Lock',
                      icon: Icon(isLocked ? Icons.lock : Icons.lock_open_outlined, color: isLocked ? accent : _muted),
                      onPressed: () async {
                        if (!repo.hasPin) {
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LiveTvSettingsScreen(focusPin: true)));
                          return;
                        }
                        if (!repo.parentalUnlocked && !await askPin(context)) return;
                        final locked = {...repo.prefs.lockedGroups};
                        if (!locked.remove(group)) locked.add(group);
                        repo.updatePrefs((p) => p.copyWith(lockedGroups: locked));
                      },
                    ),
                    IconButton(
                      tooltip: isHidden ? 'Show' : 'Hide',
                      icon: Icon(isHidden ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: isHidden ? _muted : Colors.white),
                      onPressed: () {
                        final hiddenGroups = {...repo.prefs.hiddenGroups};
                        if (!hiddenGroups.remove(group)) hiddenGroups.add(group);
                        repo.updatePrefs((p) => p.copyWith(hiddenGroups: hiddenGroups));
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _HiddenChannelsScreen extends StatelessWidget {
  const _HiddenChannelsScreen();

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('HIDDEN CHANNELS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
      body: AnimatedBuilder(
        animation: repo,
        builder: (context, _) {
          final hidden = repo.allLiveChannels.where((c) => repo.prefs.hiddenChannels.contains(c.id)).toList();
          if (hidden.isEmpty) {
            return const Center(child: Text('No hidden channels. Long-press a channel to hide it.', style: TextStyle(color: _muted)));
          }
          return ListView.builder(
            itemCount: hidden.length,
            itemBuilder: (context, index) {
              final channel = hidden[index];
              return ListTile(
                title: Text(channel.name),
                subtitle: Text(channel.group, style: const TextStyle(color: _muted)),
                trailing: TextButton(
                  onPressed: () => repo.updatePrefs((p) => p.copyWith(hiddenChannels: {...p.hiddenChannels}..remove(channel.id))),
                  child: const Text('Show'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
