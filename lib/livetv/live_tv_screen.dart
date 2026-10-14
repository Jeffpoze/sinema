import 'dart:async';

import 'package:flutter/material.dart';

import '../servers_screen.dart';
import '../settings_controller.dart';
import '../settings_screen.dart';
import '../widgets/sinema_image.dart';
import 'iptv_models.dart';
import 'iptv_player_screen.dart';
import 'iptv_repository.dart';
import 'iptv_series_screen.dart';
import 'iptv_sources_screen.dart';
import 'live_tv_settings_screen.dart';
import 'reminder_service.dart';

const _muted = Color(0xFFA5A7AC);
const _favoritesGroup = '★ Favorites';
const _recentGroup = 'Recent';
const _allGroup = 'All';

// Distinct group names in playlist order, memoized per list instance.
final Expando<List<String>> _groupsMemo = Expando();
List<String> _groupsOf(List<IptvItem> items) => _groupsMemo[items] ??= () {
      final seen = <String>{};
      return [for (final i in items) if (seen.add(i.group)) i.group];
    }();

// Live TV, TiviMate-style: channels with now/next, a guide grid, and the
// provider's movies and series — all from M3U / Xtream playlists.
class LiveTvScreen extends StatefulWidget {
  const LiveTvScreen({super.key, required this.settings, this.standalone = false});
  final SettingsController settings;
  // True when Live TV is the app's home (no media server signed in): adds a
  // menu for servers and appearance instead of a back button.
  final bool standalone;

  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen> with SingleTickerProviderStateMixin {
  final _repo = IptvRepository.instance;
  late final TabController _tabs = TabController(length: 4, vsync: this);
  final _search = TextEditingController();
  bool _searching = false;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _repo.ensureLoaded().then((_) => _maybeAutoPlay());
    ReminderService.instance.init();
    // Now/next lines and progress bars drift; nudge a repaint each minute.
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  // TiviMate's "start with last channel".
  static bool _autoPlayed = false;

  void _maybeAutoPlay() {
    if (_autoPlayed || !mounted || !_repo.prefs.autoPlayLast) return;
    final last = _repo.lastChannel;
    if (last == null) return;
    _autoPlayed = true;
    final channels = _repo.liveChannels;
    _play(context, channels, channels.indexOf(last));
  }

  void _openSources() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const IptvSourcesScreen()));

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _repo,
        builder: (context, _) => Scaffold(
          drawer: widget.standalone ? _StandaloneDrawer(settings: widget.settings) : null,
          appBar: AppBar(
            title: _searching
                ? TextField(
                    controller: _search,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Search channels, movies, series…',
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  )
                : const Text('LIVE TV', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8)),
            actions: [
              if (_repo.isAnyRefreshing)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
                ),
              if (_repo.hasSources)
                IconButton(
                  icon: Icon(_searching ? Icons.close : Icons.search),
                  onPressed: () => setState(() {
                    _searching = !_searching;
                    if (!_searching) _search.clear();
                  }),
                ),
              IconButton(icon: const Icon(Icons.playlist_add), tooltip: 'Playlists', onPressed: _openSources),
              if (_repo.hasSources)
                IconButton(
                  icon: const Icon(Icons.tune),
                  tooltip: 'Live TV settings',
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LiveTvSettingsScreen())),
                ),
            ],
            bottom: _repo.hasSources
                ? TabBar(
                    controller: _tabs,
                    isScrollable: false,
                    indicatorColor: Theme.of(context).colorScheme.primary,
                    labelColor: Colors.white,
                    unselectedLabelColor: _muted,
                    tabs: const [Tab(text: 'TV'), Tab(text: 'Guide'), Tab(text: 'Movies'), Tab(text: 'Series')],
                  )
                : null,
          ),
          body: !_repo.hasSources
              ? _EmptyState(onAdd: _openSources)
              : TabBarView(
                  controller: _tabs,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _ChannelsTab(query: _search.text),
                    const _GuideTab(),
                    _VodTab(kind: IptvKind.movie, query: _search.text),
                    _VodTab(kind: IptvKind.series, query: _search.text),
                  ],
                ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1B1D22)),
                child: const Icon(Icons.live_tv_rounded, size: 36, color: Colors.white60),
              ),
              const SizedBox(height: 20),
              const Text('Watch live TV', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                'Add your IPTV provider\'s M3U playlist or Xtream Codes login. Channels, the TV guide, movies and series all come from it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, height: 1.4),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add Playlist')),
            ],
          ),
        ),
      );
}

// ------------------------------------------------------------------ groups

class _GroupChips extends StatelessWidget {
  const _GroupChips({required this.groups, required this.selected, required this.onSelect});
  final List<String> groups;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          itemCount: groups.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final group = groups[index];
            final isSelected = group == selected;
            return ChoiceChip(
              label: Text(group),
              selected: isSelected,
              onSelected: (_) => onSelect(group),
              showCheckmark: false,
              selectedColor: Theme.of(context).colorScheme.primary,
              backgroundColor: const Color(0xFF1B1D22),
              side: BorderSide.none,
              labelStyle: TextStyle(color: isSelected ? Colors.white : const Color(0xFFD3D2D6), fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            );
          },
        ),
      );
}

// The group selection is shared by the TV list and the guide, like TiviMate.
final ValueNotifier<String> _liveGroup = ValueNotifier(_allGroup);

List<String> _liveGroupOptions(IptvRepository repo) => [
      if (repo.favoritesOf(IptvKind.live).isNotEmpty) _favoritesGroup,
      if (repo.recentChannels.isNotEmpty) _recentGroup,
      _allGroup,
      ...repo.liveGroups,
    ];

List<IptvItem> _channelsForGroup(IptvRepository repo, String group, String query) {
  final List<IptvItem> base = switch (group) {
    _favoritesGroup => repo.favoritesOf(IptvKind.live),
    _recentGroup => repo.recentChannels,
    _allGroup => repo.sorted(repo.liveChannels),
    _ => repo.sorted(repo.liveChannels.where((c) => c.group == group).toList()),
  };
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return base;
  // Search spans every channel, not just the selected group.
  return repo.liveChannels.where((c) => c.name.toLowerCase().contains(q)).toList();
}

// Parental lock: asks for the PIN once per app session.
Future<bool> ensureUnlocked(BuildContext context, IptvItem item) async {
  final repo = IptvRepository.instance;
  if (!repo.isLocked(item)) return true;
  return askPin(context);
}

Future<bool> askPin(BuildContext context, {String title = 'Enter PIN'}) async {
  final repo = IptvRepository.instance;
  final controller = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          decoration: InputDecoration(hintText: 'Parental PIN', errorText: error, counterText: ''),
          onSubmitted: (_) {
            if (repo.unlock(controller.text)) {
              Navigator.of(dialogContext).pop(true);
            } else {
              setState(() => error = 'Wrong PIN');
            }
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (repo.unlock(controller.text)) {
                Navigator.of(dialogContext).pop(true);
              } else {
                setState(() => error = 'Wrong PIN');
              }
            },
            child: const Text('Unlock'),
          ),
        ],
      ),
    ),
  );
  return ok ?? false;
}

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

Future<void> _play(BuildContext context, List<IptvItem> items, int index, {String? subtitle}) async {
  if (index < 0 || index >= items.length) return;
  if (!await ensureUnlocked(context, items[index])) return;
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => IptvPlayerScreen(items: items, initialIndex: index, subtitle: subtitle)));
}

// Replays a past (or the start of the current) programme.
Future<void> playCatchup(BuildContext context, IptvItem channel, EpgProgram program) async {
  final repo = IptvRepository.instance;
  final url = repo.catchupUrl(channel, program);
  if (url == null) return;
  if (!await ensureUnlocked(context, channel)) return;
  if (!context.mounted) return;
  final replay = channel.copyWith(url: url, kind: IptvKind.movie, name: channel.name);
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => IptvPlayerScreen(items: [replay], initialIndex: 0, subtitle: 'Catch-up · ${program.title} · ${_hhmm(program.start)}'),
  ));
}

Future<void> toggleReminder(BuildContext context, IptvItem channel, EpgProgram program) async {
  final service = ReminderService.instance;
  final adding = !service.has(channel, program);
  final ok = await service.toggle(channel, program);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(!ok
          ? 'Allow notifications for Sinema in Settings to get reminders.'
          : adding
              ? 'We\'ll remind you before ${program.title} starts.'
              : 'Reminder removed.'),
    ));
}

// Everything you can do with a channel, TiviMate-style (long-press).
Future<void> showChannelActions(BuildContext context, IptvItem channel, List<IptvItem> channels) async {
  final repo = IptvRepository.instance;
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      void close() => Navigator.of(sheetContext).pop();
      final groupLocked = repo.isGroupLocked(channel.group);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: _ChannelLogo(channel: channel, width: 44, height: 30),
              title: Text(channel.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(channel.group, style: const TextStyle(color: _muted)),
            ),
            const Divider(height: 1, color: Color(0xFF1B1D22)),
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('Watch'),
              onTap: () {
                close();
                _play(context, channels, channels.indexOf(channel));
              },
            ),
            ListTile(
              leading: const Icon(Icons.event_note_outlined),
              title: Text(channel.hasCatchup ? 'Schedule & Catch-up' : 'Schedule'),
              onTap: () {
                close();
                showChannelSchedule(context, channel, channels);
              },
            ),
            ListTile(
              leading: Icon(repo.isFavorite(channel) ? Icons.star_rounded : Icons.star_outline_rounded),
              title: Text(repo.isFavorite(channel) ? 'Remove from Favorites' : 'Add to Favorites'),
              onTap: () {
                close();
                _toggleFavorite(context, channel);
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Hide Channel'),
              subtitle: const Text('Bring it back from Live TV Settings', style: TextStyle(color: _muted)),
              onTap: () {
                close();
                repo.updatePrefs((p) => p.copyWith(hiddenChannels: {...p.hiddenChannels, channel.id}));
              },
            ),
            ListTile(
              leading: Icon(groupLocked ? Icons.lock_open_outlined : Icons.lock_outline),
              title: Text(groupLocked ? 'Unlock "${channel.group}"' : 'Lock "${channel.group}"'),
              onTap: () async {
                close();
                if (!repo.hasPin) {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LiveTvSettingsScreen(focusPin: true)));
                  return;
                }
                if (!await askPin(context, title: 'Enter PIN to change locks')) return;
                final locked = {...repo.prefs.lockedGroups};
                if (!locked.remove(channel.group)) locked.add(channel.group);
                repo.updatePrefs((p) => p.copyWith(lockedGroups: locked));
              },
            ),
          ],
        ),
      );
    },
  );
}

// A channel's full programme list: catch-up for what's aired, reminders for
// what's coming.
Future<void> showChannelSchedule(BuildContext context, IptvItem channel, List<IptvItem> channels) async {
  final repo = IptvRepository.instance;
  final now = DateTime.now();
  final days = channel.catchupDays ?? 0;
  final earliest = now.subtract(Duration(days: days > 0 ? days : 0, hours: days > 0 ? 0 : 1));
  final programs = repo.programsFor(channel).where((p) => p.end.isAfter(earliest)).toList();
  final currentIndex = programs.indexWhere((p) => p.isAiringAt(now));
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.of(sheetContext).size.height * .75,
      child: AnimatedBuilder(
        animation: Listenable.merge([repo, ReminderService.instance]),
        builder: (sheetContext, _) {
          final accent = Theme.of(sheetContext).colorScheme.primary;
          return Column(
            children: [
              ListTile(
                leading: _ChannelLogo(channel: channel, width: 44, height: 30),
                title: Text(channel.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(channel.hasCatchup ? 'Catch-up: ${channel.catchupDays} days' : channel.group, style: const TextStyle(color: _muted)),
              ),
              const Divider(height: 1, color: Color(0xFF1B1D22)),
              Expanded(
                child: programs.isEmpty
                    ? const Center(child: Text('No guide information for this channel.', style: TextStyle(color: _muted)))
                    : ListView.builder(
                        // Open on what's airing now; scroll up for catch-up.
                        controller: ScrollController(initialScrollOffset: currentIndex <= 0 ? 0 : currentIndex * 64.0),
                        itemExtent: 64,
                        itemCount: programs.length,
                        itemBuilder: (context, index) {
                          final p = programs[index];
                          final airing = p.isAiringAt(now);
                          final past = p.end.isBefore(now);
                          final catchup = repo.canCatchup(channel, p);
                          final reminded = ReminderService.instance.has(channel, p);
                          final dayLabel = DateUtils.isSameDay(p.start, now) ? '' : '${_weekday(p.start)} ';
                          return ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            tileColor: airing ? accent.withValues(alpha: .12) : null,
                            leading: SizedBox(
                              width: 64,
                              child: Text('$dayLabel${_hhmm(p.start)}', style: TextStyle(color: airing ? accent : (past ? _muted : Colors.white), fontWeight: FontWeight.w600)),
                            ),
                            title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: past && !catchup ? _muted : Colors.white)),
                            subtitle: p.description == null ? null : Text(p.description!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted)),
                            trailing: airing
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (catchup)
                                        IconButton(tooltip: 'Watch from start', icon: const Icon(Icons.replay), onPressed: () {
                                          Navigator.of(sheetContext).pop();
                                          playCatchup(context, channel, p);
                                        }),
                                      Icon(Icons.circle, size: 10, color: accent),
                                    ],
                                  )
                                : past
                                    ? (catchup ? const Icon(Icons.history, color: Colors.white70) : null)
                                    : IconButton(
                                        tooltip: reminded ? 'Remove reminder' : 'Remind me',
                                        icon: Icon(reminded ? Icons.notifications_active : Icons.notifications_none, color: reminded ? accent : Colors.white70),
                                        onPressed: () => toggleReminder(context, channel, p),
                                      ),
                            onTap: () {
                              if (airing) {
                                Navigator.of(sheetContext).pop();
                                _play(context, channels.contains(channel) ? channels : [channel], channels.contains(channel) ? channels.indexOf(channel) : 0);
                              } else if (past && catchup) {
                                Navigator.of(sheetContext).pop();
                                playCatchup(context, channel, p);
                              } else if (!past) {
                                toggleReminder(context, channel, p);
                              }
                            },
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

String _weekday(DateTime t) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1];

void _toggleFavorite(BuildContext context, IptvItem item) {
  final repo = IptvRepository.instance;
  final adding = !repo.isFavorite(item);
  repo.toggleFavorite(item);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(adding ? 'Added ${item.name} to Favorites' : 'Removed ${item.name} from Favorites'), duration: const Duration(seconds: 2)));
}

// -------------------------------------------------------------------- TV

class _ChannelsTab extends StatelessWidget {
  const _ChannelsTab({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    return ValueListenableBuilder<String>(
      valueListenable: _liveGroup,
      builder: (context, group, _) {
        final options = _liveGroupOptions(repo);
        final selected = options.contains(group) ? group : _allGroup;
        final channels = _channelsForGroup(repo, selected, query);
        return Column(
          children: [
            if (query.isEmpty) _GroupChips(groups: options, selected: selected, onSelect: (g) => _liveGroup.value = g),
            Expanded(
              child: query.trim().isNotEmpty
                  ? _SearchResults(channels: channels, query: query)
                  : channels.isEmpty
                      ? Center(child: Text(repo.isAnyRefreshing ? 'Loading channels…' : 'No channels here.', style: const TextStyle(color: _muted)))
                      : ListView.builder(
                          itemExtent: 76,
                          itemCount: channels.length,
                          itemBuilder: (context, index) => _ChannelRow(
                            channel: channels[index],
                            position: index,
                            onTap: () => _play(context, channels, index),
                            onLongPress: () => showChannelActions(context, channels[index], channels),
                          ),
                        ),
            ),
          ],
        );
      },
    );
  }
}

// Search: matching channels, then matching shows from the guide.
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.channels, required this.query});
  final List<IptvItem> channels;
  final String query;

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    final programs = repo.searchPrograms(query);
    final allChannels = repo.liveChannels;
    if (channels.isEmpty && programs.isEmpty) {
      return const Center(child: Text('Nothing matches.', style: TextStyle(color: _muted)));
    }
    return ListView(
      children: [
        if (channels.isNotEmpty) const _SectionLabel('Channels'),
        for (var i = 0; i < channels.length && i < 40; i++)
          SizedBox(
            height: 76,
            child: _ChannelRow(
              channel: channels[i],
              position: i,
              onTap: () => _play(context, channels, i),
              onLongPress: () => showChannelActions(context, channels[i], channels),
            ),
          ),
        if (programs.isNotEmpty) const _SectionLabel('On the Guide'),
        for (final r in programs)
          ListTile(
            leading: _ChannelLogo(channel: r.channel, width: 44, height: 30),
            title: Text(r.program.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${r.channel.name} · ${DateUtils.isSameDay(r.program.start, DateTime.now()) ? '' : '${_weekday(r.program.start)} '}${_hhmm(r.program.start)}',
              style: const TextStyle(color: _muted),
            ),
            trailing: r.program.isAiringAt(DateTime.now())
                ? Icon(Icons.circle, size: 10, color: Theme.of(context).colorScheme.primary)
                : AnimatedBuilder(
                    animation: ReminderService.instance,
                    builder: (context, _) => IconButton(
                      icon: Icon(ReminderService.instance.has(r.channel, r.program) ? Icons.notifications_active : Icons.notifications_none),
                      onPressed: () => toggleReminder(context, r.channel, r.program),
                    ),
                  ),
            onTap: () => r.program.isAiringAt(DateTime.now())
                ? _play(context, allChannels, allChannels.indexOf(r.channel))
                : showChannelSchedule(context, r.channel, allChannels),
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: _muted)),
      );
}

class _ChannelLogo extends StatelessWidget {
  const _ChannelLogo({required this.channel, this.width = 56, this.height = 40});
  final IptvItem channel;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: const Color(0xFF1B1D22), borderRadius: BorderRadius.circular(6)),
      child: Text(
        channel.name.isEmpty ? '?' : channel.name.characters.first.toUpperCase(),
        style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.white54),
      ),
    );
    final logo = channel.logo;
    if (logo == null) return fallback;
    return SizedBox(
      width: width,
      height: height,
      child: SinemaImage(imageUrl: logo, fit: BoxFit.contain, memCacheWidth: (width * 3).round(), errorWidget: (_, _, _) => fallback),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({required this.channel, required this.position, required this.onTap, required this.onLongPress});
  final IptvItem channel;
  final int position;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    final now = repo.nowPlaying(channel);
    final next = repo.upNext(channel);
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Text(channel.number?.toString() ?? '${position + 1}', style: const TextStyle(color: _muted, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            _ChannelLogo(channel: channel),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                      if (repo.isFavorite(channel)) Icon(Icons.star_rounded, size: 16, color: accent),
                    ],
                  ),
                  if (now != null) ...[
                    const SizedBox(height: 3),
                    Text(now.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Color(0xFFD3D2D6))),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(value: now.progressAt(DateTime.now()), minHeight: 3, color: accent, backgroundColor: Colors.white12),
                          ),
                        ),
                        if (next != null) ...[
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text('${_hhmm(next.start)} ${next.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: _muted)),
                          ),
                        ],
                      ],
                    ),
                  ] else
                    Text(channel.group, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: _muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Guide

class _GuideTab extends StatefulWidget {
  const _GuideTab();

  @override
  State<_GuideTab> createState() => _GuideTabState();
}

class _GuideTabState extends State<_GuideTab> {
  static const _pxPerMinute = 4.0;
  static const _channelColumn = 112.0;
  static const _rowHeight = 64.0;
  static const _span = Duration(hours: 24);

  // The grid starts half an hour before now (rounded to the half hour) so
  // what's on right now is visible straight away with a bit of context.
  late final DateTime _origin = () {
    final now = DateTime.now();
    final rounded = DateTime(now.year, now.month, now.day, now.hour, now.minute >= 30 ? 30 : 0);
    return rounded.subtract(const Duration(minutes: 30));
  }();
  double _offset = 0;

  double _xFor(DateTime t) => t.difference(_origin).inSeconds / 60 * _pxPerMinute;

  void _showProgram(IptvItem channel, EpgProgram program, List<IptvItem> channels) {
    final airing = program.isAiringAt(DateTime.now());
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _ChannelLogo(channel: channel, width: 44, height: 30),
                  const SizedBox(width: 10),
                  Expanded(child: Text(channel.name, style: const TextStyle(color: _muted))),
                ],
              ),
              const SizedBox(height: 14),
              Text(program.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('${_hhmm(program.start)} – ${_hhmm(program.end)}', style: const TextStyle(color: _muted)),
              if (program.description != null && program.description!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(program.description!, maxLines: 8, overflow: TextOverflow.ellipsis, style: const TextStyle(height: 1.4)),
              ],
              const SizedBox(height: 20),
              if (IptvRepository.instance.canCatchup(channel, program)) ...[
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      playCatchup(context, channel, program);
                    },
                    icon: const Icon(Icons.replay),
                    label: Text(airing ? 'Watch from Start' : 'Watch (Catch-up)'),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (program.start.isAfter(DateTime.now())) ...[
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: AnimatedBuilder(
                    animation: ReminderService.instance,
                    builder: (context, _) {
                      final set = ReminderService.instance.has(channel, program);
                      return OutlinedButton.icon(
                        onPressed: () => toggleReminder(context, channel, program),
                        icon: Icon(set ? Icons.notifications_active : Icons.notifications_none),
                        label: Text(set ? 'Reminder Set' : 'Remind Me'),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
              ],
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    _play(context, channels, channels.indexOf(channel));
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: Text(airing ? 'Watch Now' : 'Watch ${channel.name} Live'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    if (!repo.hasGuide) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No TV guide yet. Add an EPG (XMLTV) URL to your playlist — Xtream Codes logins use the provider\'s guide automatically.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, height: 1.4),
          ),
        ),
      );
    }
    final accent = Theme.of(context).colorScheme.primary;
    return ValueListenableBuilder<String>(
      valueListenable: _liveGroup,
      builder: (context, group, _) {
        final options = _liveGroupOptions(repo);
        final selected = options.contains(group) ? group : _allGroup;
        final channels = _channelsForGroup(repo, selected, '');
        return Column(
          children: [
            _GroupChips(groups: options, selected: selected, onSelect: (g) => _liveGroup.value = g),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewport = constraints.maxWidth - _channelColumn;
                  final maxOffset = (_span.inMinutes * _pxPerMinute - viewport).clamp(0.0, double.infinity);
                  final visibleStart = _origin.add(Duration(seconds: (_offset / _pxPerMinute * 60).round()));
                  final visibleEnd = visibleStart.add(Duration(seconds: (viewport / _pxPerMinute * 60).round()));
                  final nowX = _xFor(DateTime.now()) - _offset;
                  return GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (d) => setState(() => _offset = (_offset - d.delta.dx).clamp(0.0, maxOffset)),
                    child: Column(
                      children: [
                        // Time ruler.
                        SizedBox(
                          height: 30,
                          child: Row(
                            children: [
                              SizedBox(
                                width: _channelColumn,
                                child: Center(child: Text(_hhmm(DateTime.now()), style: TextStyle(color: accent, fontWeight: FontWeight.w700))),
                              ),
                              Expanded(
                                child: ClipRect(
                                  child: Stack(
                                    children: [
                                      for (var m = 0; m <= _span.inMinutes; m += 30)
                                        if (m * _pxPerMinute - _offset > -120 && m * _pxPerMinute - _offset < viewport)
                                          Positioned(
                                            left: m * _pxPerMinute - _offset + 6,
                                            top: 6,
                                            child: Text(_hhmm(_origin.add(Duration(minutes: m))), style: const TextStyle(fontSize: 12, color: _muted)),
                                          ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Stack(
                            children: [
                              ListView.builder(
                                itemExtent: _rowHeight,
                                itemCount: channels.length,
                                itemBuilder: (context, index) {
                                  final channel = channels[index];
                                  final programs = repo.programsFor(channel).where((p) => p.end.isAfter(visibleStart) && p.start.isBefore(visibleEnd));
                                  return Row(
                                    children: [
                                      InkWell(
                                        onTap: () => _play(context, channels, index),
                                        onLongPress: () => showChannelActions(context, channel, channels),
                                        child: Container(
                                          width: _channelColumn,
                                          height: _rowHeight,
                                          padding: const EdgeInsets.symmetric(horizontal: 8),
                                          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF1B1D22)), right: BorderSide(color: Color(0xFF1B1D22)))),
                                          child: Row(
                                            children: [
                                              _ChannelLogo(channel: channel, width: 36, height: 26),
                                              const SizedBox(width: 6),
                                              Expanded(child: Text(channel.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                                            ],
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: ClipRect(
                                          child: Stack(
                                            children: [
                                              for (final p in programs)
                                                Positioned(
                                                  left: _xFor(p.start) - _offset,
                                                  width: ((p.end.difference(p.start).inSeconds / 60) * _pxPerMinute).clamp(2.0, double.infinity),
                                                  top: 0,
                                                  bottom: 0,
                                                  child: _ProgramCell(
                                                    program: p,
                                                    airing: p.isAiringAt(DateTime.now()),
                                                    accent: accent,
                                                    // Keep the title readable when a show started before the visible window.
                                                    textInset: (_offset - _xFor(p.start)).clamp(0.0, double.infinity),
                                                    onTap: () => _showProgram(channel, p, channels),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              if (nowX >= 0 && nowX <= viewport)
                                Positioned(
                                  left: _channelColumn + nowX,
                                  top: 0,
                                  bottom: 0,
                                  child: IgnorePointer(child: Container(width: 2, color: accent)),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ProgramCell extends StatelessWidget {
  const _ProgramCell({required this.program, required this.airing, required this.accent, required this.textInset, required this.onTap});
  final EpgProgram program;
  final bool airing;
  final Color accent;
  final double textInset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.fromLTRB(1, 3, 1, 3),
          padding: EdgeInsets.fromLTRB(8 + textInset, 6, 6, 6),
          decoration: BoxDecoration(
            color: airing ? accent.withValues(alpha: .22) : const Color(0xFF16181C),
            borderRadius: BorderRadius.circular(6),
            border: airing ? Border.all(color: accent.withValues(alpha: .5)) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(program.title, maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              Text('${_hhmm(program.start)} – ${_hhmm(program.end)}', maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: const TextStyle(fontSize: 10, color: _muted)),
            ],
          ),
        ),
      );
}

// ---------------------------------------------------------- Movies/Series

class _VodTab extends StatefulWidget {
  const _VodTab({required this.kind, required this.query});
  final IptvKind kind;
  final String query;

  @override
  State<_VodTab> createState() => _VodTabState();
}

class _VodTabState extends State<_VodTab> with AutomaticKeepAliveClientMixin {
  String _group = _allGroup;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final repo = IptvRepository.instance;
    final all = widget.kind == IptvKind.movie ? repo.movies : repo.series;
    final favorites = repo.favoritesOf(widget.kind);
    final options = [if (favorites.isNotEmpty) _favoritesGroup, _allGroup, ..._groupsOf(all)];
    final selected = options.contains(_group) ? _group : _allGroup;
    final q = widget.query.trim().toLowerCase();
    final List<IptvItem> items = q.isNotEmpty
        ? all.where((i) => i.name.toLowerCase().contains(q)).toList()
        : switch (selected) {
            _favoritesGroup => favorites,
            _allGroup => all,
            _ => all.where((i) => i.group == selected).toList(),
          };
    final label = widget.kind == IptvKind.movie ? 'movies' : 'series';
    if (all.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            repo.isAnyRefreshing ? 'Loading $label…' : 'Your playlists don\'t include any $label.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted),
          ),
        ),
      );
    }
    return Column(
      children: [
        if (q.isEmpty) _GroupChips(groups: options, selected: selected, onSelect: (g) => setState(() => _group = g)),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisSpacing: 16, crossAxisSpacing: 12, childAspectRatio: 0.52),
            itemCount: items.length,
            itemBuilder: (context, index) => _PosterCard(item: items[index]),
          ),
        ),
      ],
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({required this.item});
  final IptvItem item;

  void _open(BuildContext context) {
    if (item.kind == IptvKind.series) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => IptvSeriesScreen(show: item)));
    } else {
      _showMovie(context, item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    final title = item.kind == IptvKind.series ? (item.seriesName ?? item.name) : item.name;
    return GestureDetector(
      onTap: () => _open(context),
      onLongPress: () => _toggleFavorite(context, item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  item.logo == null
                      ? const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.movie_outlined, color: Colors.white24))
                      : SinemaImage(imageUrl: item.logo!, fit: BoxFit.cover, memCacheWidth: 300, errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.movie_outlined, color: Colors.white24))),
                  if (repo.isFavorite(item))
                    Positioned(top: 6, right: 6, child: Icon(Icons.star_rounded, size: 20, color: Theme.of(context).colorScheme.primary, shadows: const [Shadow(blurRadius: 6)])),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          if (item.year != null) Text(item.year!, style: const TextStyle(fontSize: 11, color: _muted)),
        ],
      ),
    );
  }
}

void _showMovie(BuildContext context, IptvItem movie) {
  final repo = IptvRepository.instance;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => AnimatedBuilder(
      animation: repo,
      builder: (sheetContext, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 100,
                      height: 150,
                      child: movie.logo == null
                          ? const ColoredBox(color: Color(0xFF17191D))
                          : SinemaImage(imageUrl: movie.logo!, fit: BoxFit.cover, memCacheWidth: 300, errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF17191D))),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(movie.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text([movie.group, if (movie.year != null) movie.year!, if (movie.rating != null && movie.rating != '0') '★ ${movie.rating}'].join(' · '), style: const TextStyle(color: _muted)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          _play(context, [movie], 0);
                        },
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(
                    onPressed: () => repo.toggleFavorite(movie),
                    icon: Icon(repo.isFavorite(movie) ? Icons.star_rounded : Icons.star_outline_rounded),
                    style: IconButton.styleFrom(fixedSize: const Size(48, 48)),
                    tooltip: 'Favorite',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _StandaloneDrawer extends StatelessWidget {
  const _StandaloneDrawer({required this.settings});
  final SettingsController settings;

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) => Drawer(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Text('SINEMA', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.4, color: _muted)),
              ),
              ListTile(
                leading: const Icon(Icons.connected_tv_outlined),
                title: const Text('Live TV'),
                selected: true,
                selectedTileColor: const Color(0xFF1B1D22),
                onTap: () => Navigator.of(context).pop(),
              ),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Media Servers'),
                subtitle: const Text('Connect Jellyfin or Emby', style: TextStyle(color: _muted)),
                onTap: () => _open(context, ServersScreen(settings: settings)),
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('Playlists'),
                onTap: () => _open(context, const IptvSourcesScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('Appearance'),
                onTap: () => _open(context, AppearanceScreen(settings: settings)),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('About'),
                onTap: () => _open(context, const AboutScreen()),
              ),
            ],
          ),
        ),
      );
}
