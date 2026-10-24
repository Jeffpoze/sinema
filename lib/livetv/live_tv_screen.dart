import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../servers_screen.dart';
import '../settings_controller.dart';
import '../settings_screen.dart';
import '../widgets/sinema_image.dart';
import 'iptv_models.dart';
import 'iptv_player_screen.dart';
import 'iptv_repository.dart';
import 'iptv_series_screen.dart';
import 'iptv_sources_screen.dart';
import 'live_playback.dart';
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
  late final TabController _tabs = TabController(length: 5, vsync: this);
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
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(56),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      // Plex-style pill tabs.
                      child: TabBar(
                        controller: _tabs,
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        labelPadding: const EdgeInsets.symmetric(horizontal: 18),
                        dividerColor: Colors.transparent,
                        indicatorSize: TabBarIndicatorSize.tab,
                        indicator: ShapeDecoration(shape: StadiumBorder(side: BorderSide(color: Colors.white.withValues(alpha: .55), width: 1.5))),
                        splashBorderRadius: BorderRadius.circular(24),
                        labelColor: Colors.white,
                        unselectedLabelColor: _muted,
                        labelStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        unselectedLabelStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        tabs: const [Tab(text: 'Guide'), Tab(text: "What's On"), Tab(text: 'Channels'), Tab(text: 'Movies'), Tab(text: 'Series')],
                      ),
                    ),
                  )
                : null,
          ),
          body: !_repo.hasSources
              ? _EmptyState(onAdd: _openSources)
              : TabBarView(
                  controller: _tabs,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    // Searching from the Guide or What's On shows results in place.
                    _search.text.trim().isEmpty ? const _GuideTab() : _ChannelsTab(query: _search.text),
                    _search.text.trim().isEmpty ? const _WhatsOnTab() : _ChannelsTab(query: _search.text),
                    _ChannelsTab(query: _search.text),
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

// Clock time in the phone's own 12/24-hour style ("9:30 PM" or "21:30").
String _clockOf(BuildContext context, DateTime t) =>
    MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));

String _timeLeft(EpgProgram p, DateTime now) {
  final left = p.end.difference(now);
  if (left.inMinutes < 1) return 'Ending';
  if (left.inMinutes < 60) return '${left.inMinutes}m left';
  final h = left.inHours;
  final m = left.inMinutes.remainder(60);
  return m == 0 ? '${h}h left' : '${h}h ${m}m left';
}

String _dayLabel(DateTime day, DateTime now) {
  final d = DateUtils.dateOnly(day);
  final today = DateUtils.dateOnly(now);
  final diff = d.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  return '${_weekday(d)} ${d.day}';
}

// Programme details: watch, catch-up, reminder.
void _showProgram(BuildContext context, IptvItem channel, EpgProgram program, List<IptvItem> channels, {VoidCallback? onWatch}) {
  final airing = program.isAiringAt(DateTime.now());
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (program.icon != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: SinemaImage(imageUrl: program.icon!, fit: BoxFit.cover, errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF16181C))),
                  ),
                ),
              ),
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
            Text(
              [
                '${_dayLabel(program.start, DateTime.now())} · ${_clockOf(context, program.start)} – ${_clockOf(context, program.end)}',
                if (airing) _timeLeft(program, DateTime.now()),
                if (program.category != null) program.category!,
              ].join(' · '),
              style: const TextStyle(color: _muted),
            ),
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
                  if (onWatch != null) {
                    onWatch();
                  } else {
                    _play(context, channels, channels.indexOf(channel));
                  }
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

// Plex-style guide: a muted live preview of the channel you tap on top, then
// a day/time bar and the grid of channel tiles and programme cards with a
// "now" line. Tap a channel (or what's on it now) to preview it, tap the
// preview again or its expand button to watch full screen.
class _GuideTab extends StatefulWidget {
  const _GuideTab();

  @override
  State<_GuideTab> createState() => _GuideTabState();
}

class _GuideTabState extends State<_GuideTab> {
  static const _pxPerMinute = 5.0;
  static const _channelColumn = 84.0;
  static const _rowHeight = 78.0;

  final _repo = IptvRepository.instance;

  // The grid's time axis starts at the beginning of yesterday when any channel
  // has catch-up (so past shows are reachable), otherwise at today's midnight,
  // and runs two days ahead — as far as guides usually go.
  late final DateTime _origin = () {
    final today = DateUtils.dateOnly(DateTime.now());
    return _repo.liveChannels.any((c) => c.hasCatchup) ? today.subtract(const Duration(days: 1)) : today;
  }();
  late final DateTime _end = DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 3));
  late double _offset = _xFor(_roundedNow().subtract(const Duration(minutes: 30)));

  // Live preview: hidden until you pick a channel, like Plex.
  Player? _player;
  VideoController? _video;
  MpvLogTail? _previewLog;
  IptvItem? _previewing;
  bool _previewMuted = true;
  double _previewVolume = 70;
  bool _previewFailed = false;
  String _previewError = '';
  StreamSubscription<String>? _previewErrors;
  Timer? _previewWatchdog;

  @override
  void initState() {
    super.initState();
    IptvPlayerScreen.openCount.addListener(_onFullScreenChanged);
  }

  @override
  void dispose() {
    IptvPlayerScreen.openCount.removeListener(_onFullScreenChanged);
    _stopPreview();
    super.dispose();
  }

  // Full-screen player opened (from anywhere): stop the preview. Closed: if
  // the preview was showing, bring it back on whatever was watched last.
  void _onFullScreenChanged() {
    if (!mounted) return;
    if (IptvPlayerScreen.openCount.value > 0) {
      if (_player != null) setState(_stopPreview);
    } else if (_previewing != null) {
      final last = _repo.lastChannel ?? _previewing!;
      if (!_repo.isLocked(last)) _preview(last);
    }
  }

  static DateTime _roundedNow() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, now.hour, now.minute >= 30 ? 30 : 0);
  }

  double _xFor(DateTime t) => t.difference(_origin).inSeconds / 60 * _pxPerMinute;
  DateTime _timeAt(double x) => _origin.add(Duration(seconds: (x / _pxPerMinute * 60).round()));
  double get _maxOffset => _xFor(_end);

  void _jumpTo(DateTime t) => setState(() => _offset = _xFor(t).clamp(0.0, _maxOffset));

  double get _effectiveVolume => _previewMuted ? 0 : _previewVolume;

  Future<void> _preview(IptvItem channel, {bool softwareDecode = false}) async {
    if (!await ensureUnlocked(context, channel) || !mounted || IptvPlayerScreen.openCount.value > 0) return;
    // A fresh player each time keeps a failed decoder from sticking around.
    _stopPreview();
    final player = Player(configuration: const PlayerConfiguration(bufferSize: 8 * 1024 * 1024, logLevel: liveLogLevel));
    _player = player;
    _video = VideoController(player);
    _previewLog = MpvLogTail(player);
    _previewErrors = player.stream.error.listen((message) {
      if (message.isNotEmpty) _previewError = message;
    });
    setState(() {
      _previewing = channel;
      _previewFailed = false;
      _previewError = '';
    });
    await videoReady(_video!);
    await tuneForLive(player, softwareDecode: softwareDecode);
    if (_player != player) return;
    final headers = _repo.sourceFor(channel.sourceId)?.headers ?? const <String, String>{};
    try {
      await player.setVolume(_effectiveVolume);
      await player.open(Media(_repo.playbackUrl(channel), httpHeaders: headers.isEmpty ? null : headers));
    } catch (e) {
      _previewError = e.toString();
    }
    // Nothing playing after a while: first retry with software decoding (some
    // channels won't hardware-decode), then say what went wrong.
    _previewWatchdog?.cancel();
    _previewWatchdog = Timer(Duration(seconds: softwareDecode ? 15 : 10), () {
      if (!mounted || _player != player || player.state.position > Duration.zero) return;
      if (!softwareDecode) {
        _preview(channel, softwareDecode: true);
      } else {
        // Give up and release the provider connection.
        setState(() {
          _previewFailed = true;
          _stopPreview();
        });
      }
    });
  }

  // Frees the provider connection: many plans allow a single stream, so the
  // preview must stop before the full-screen player starts.
  void _stopPreview() {
    _previewWatchdog?.cancel();
    _previewErrors?.cancel();
    _previewErrors = null;
    _previewLog?.dispose();
    _player?.dispose();
    _player = null;
    _video = null;
  }

  void _closePreview() => setState(() {
        _stopPreview();
        _previewLog = null;
        _previewing = null;
        _previewFailed = false;
      });

  Future<void> _watchFullScreen(IptvItem channel, List<IptvItem> channels) async {
    final list = channels.contains(channel) ? channels : [channel];
    // Free the stream first; the preview resumes when full screen closes.
    setState(_stopPreview);
    await _play(context, list, list.indexOf(channel));
  }

  void _toggleMute() {
    setState(() {
      _previewMuted = !_previewMuted;
      if (!_previewMuted && _previewVolume < 5) _previewVolume = 50;
    });
    _player?.setVolume(_effectiveVolume);
  }

  void _setVolume(double v) {
    setState(() {
      _previewVolume = v;
      _previewMuted = v < 1;
    });
    _player?.setVolume(_effectiveVolume);
  }

  void _onChannelTap(IptvItem channel, List<IptvItem> channels) {
    if (_previewing?.id == channel.id && _player != null && !_previewFailed) {
      _watchFullScreen(channel, channels);
    } else {
      _preview(channel);
    }
  }

  void _onProgramTap(IptvItem channel, EpgProgram program, List<IptvItem> channels) {
    if (program.isAiringAt(DateTime.now())) {
      _onChannelTap(channel, channels);
    } else {
      _showProgram(context, channel, program, channels, onWatch: () => _watchFullScreen(channel, channels));
    }
  }

  Future<void> _pickDay(BuildContext anchor) async {
    final now = DateTime.now();
    final days = <DateTime>[
      for (var d = _origin; d.isBefore(_end); d = DateUtils.addDaysToDate(d, 1)) d,
    ];
    final box = anchor.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset(0, box.size.height), ancestor: overlay);
    final picked = await showMenu<DateTime>(
      context: context,
      position: RelativeRect.fromLTRB(topLeft.dx, topLeft.dy + 4, overlay.size.width - topLeft.dx - box.size.width, 0),
      color: const Color(0xFF1E2025),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: [for (final d in days) PopupMenuItem(value: d, child: Text(_dayLabel(d, now)))],
    );
    if (picked == null) return;
    if (DateUtils.isSameDay(picked, now)) {
      _jumpTo(_roundedNow().subtract(const Duration(minutes: 30)));
    } else {
      // Same time of day on the chosen day; evenings for future days.
      final hour = picked.isAfter(now) ? 18 : now.hour;
      _jumpTo(DateTime(picked.year, picked.month, picked.day, hour));
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ValueListenableBuilder<String>(
      valueListenable: _liveGroup,
      builder: (context, group, _) {
        final options = _liveGroupOptions(_repo);
        final selected = options.contains(group) ? group : _allGroup;
        final channels = _channelsForGroup(_repo, selected, '');
        final now = DateTime.now();
        final visibleStart = _timeAt(_offset);
        return Column(
          children: [
            // The preview slides in when you pick a channel and away when closed.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _previewing == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: _LivePreview(
                        channel: _previewing!,
                        video: _video,
                        program: _repo.nowPlaying(_previewing!),
                        muted: _previewMuted,
                        volume: _previewVolume,
                        failed: _previewFailed,
                        error: [if (_previewError.isNotEmpty) _previewError, if (_previewLog != null && _previewLog!.summary.isNotEmpty) _previewLog!.summary].join('\n'),
                        onToggleMute: _toggleMute,
                        onVolume: _setVolume,
                        onExpand: () => _watchFullScreen(_previewing!, channels),
                        onClose: _closePreview,
                        onRetry: () => _preview(_previewing!),
                      ),
                    ),
            ),
            // Day + time bar.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Builder(
                    builder: (anchor) => Material(
                      color: const Color(0xFF1E2025),
                      shape: const StadiumBorder(),
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: () => _pickDay(anchor),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 9, 12, 9),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_dayLabel(visibleStart, now), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                              const SizedBox(width: 6),
                              const Icon(Icons.keyboard_arrow_down, size: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(_clockOf(context, visibleStart), style: const TextStyle(color: Color(0xFFD3D2D6), fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if ((_xFor(now) - _offset).abs() > 60 * _pxPerMinute)
                    TextButton(onPressed: () => _jumpTo(_roundedNow().subtract(const Duration(minutes: 30))), child: const Text('Now')),
                  _RoundButton(icon: Icons.chevron_left, onTap: () => setState(() => _offset = (_offset - 60 * _pxPerMinute).clamp(0.0, _maxOffset))),
                  const SizedBox(width: 8),
                  _RoundButton(icon: Icons.chevron_right, onTap: () => setState(() => _offset = (_offset + 60 * _pxPerMinute).clamp(0.0, _maxOffset))),
                ],
              ),
            ),
            _GroupChips(groups: options, selected: selected, onSelect: (g) => _liveGroup.value = g),
            Expanded(
              child: !_repo.hasGuide && channels.isEmpty
                  ? Center(child: Text(_repo.isAnyRefreshing ? 'Loading channels…' : 'No channels here.', style: const TextStyle(color: _muted)))
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final viewport = constraints.maxWidth - _channelColumn - 16;
                        final visibleEnd = _timeAt(_offset + viewport);
                        final nowX = _xFor(now) - _offset;
                        return GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragUpdate: (d) => setState(() => _offset = (_offset - d.delta.dx).clamp(0.0, _maxOffset)),
                          child: Stack(
                            children: [
                              ListView.builder(
                                padding: const EdgeInsets.only(left: 16, bottom: 24),
                                itemExtent: _rowHeight,
                                itemCount: channels.length,
                                itemBuilder: (context, index) {
                                  final channel = channels[index];
                                  final programs = _repo.programsFor(channel).where((p) => p.end.isAfter(visibleStart) && p.start.isBefore(visibleEnd)).toList();
                                  final isPreviewing = _previewing?.id == channel.id;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      children: [
                                        _ChannelTile(
                                          channel: channel,
                                          position: index,
                                          selected: isPreviewing,
                                          onTap: () => _onChannelTap(channel, channels),
                                          onLongPress: () => showChannelActions(context, channel, channels),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: ClipRect(
                                            child: programs.isEmpty
                                                ? _GuideCard(
                                                    title: channel.name,
                                                    subtitle: 'No guide information',
                                                    selected: isPreviewing,
                                                    dim: true,
                                                    textInset: 0,
                                                    onTap: () => _onChannelTap(channel, channels),
                                                  )
                                                : Stack(
                                                    children: [
                                                      for (final p in programs)
                                                        Positioned(
                                                          left: _xFor(p.start) - _offset,
                                                          width: ((p.end.difference(p.start).inSeconds / 60) * _pxPerMinute).clamp(4.0, double.infinity),
                                                          top: 0,
                                                          bottom: 0,
                                                          child: _GuideCard(
                                                            title: p.title,
                                                            subtitle: p.isAiringAt(now) ? _timeLeft(p, now) : _clockOf(context, p.start),
                                                            selected: isPreviewing && p.isAiringAt(now),
                                                            dim: p.end.isBefore(now) && !_repo.canCatchup(channel, p),
                                                            // Keep the title readable when a show started before the visible window.
                                                            textInset: (_offset - _xFor(p.start)).clamp(0.0, double.infinity),
                                                            onTap: () => _onProgramTap(channel, p, channels),
                                                            onLongPress: () => _showProgram(context, channel, p, channels, onWatch: () => _watchFullScreen(channel, channels)),
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                              if (nowX >= 0 && nowX <= viewport)
                                Positioned(
                                  left: 16 + _channelColumn + 8 + nowX - 7,
                                  top: 0,
                                  bottom: 0,
                                  child: IgnorePointer(
                                    child: Column(
                                      children: [
                                        CustomPaint(size: const Size(14, 9), painter: _TrianglePainter(accent)),
                                        Expanded(child: Container(width: 2, color: accent)),
                                      ],
                                    ),
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

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF1E2025),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 24)),
        ),
      );
}

class _TrianglePainter extends CustomPainter {
  const _TrianglePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.color != color;
}

// Square channel tile: logo with the channel number along the bottom.
class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel, required this.position, required this.selected, required this.onTap, required this.onLongPress});
  final IptvItem channel;
  final int position;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: _GuideTabState._channelColumn,
      child: Material(
        color: const Color(0xFF16181C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: selected ? BorderSide(color: accent, width: 1.5) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                  child: Center(child: _ChannelLogo(channel: channel, width: 60, height: 34)),
                ),
              ),
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                padding: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: .45), borderRadius: BorderRadius.circular(6)),
                child: Text(
                  channel.number?.toString() ?? '${position + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? accent : Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuideCard extends StatelessWidget {
  const _GuideCard({required this.title, required this.subtitle, required this.selected, required this.dim, required this.textInset, required this.onTap, this.onLongPress});
  final String title;
  final String subtitle;
  final bool selected;
  final bool dim;
  final double textInset;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: const Color(0xFF1E2025),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: selected ? const BorderSide(color: Colors.white70, width: 1.5) : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: EdgeInsets.fromLTRB(14 + textInset, 8, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: dim ? _muted : Colors.white),
                  ),
                  const SizedBox(height: 3),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: const TextStyle(fontSize: 13, color: _muted)),
                ],
              ),
            ),
          ),
        ),
      );
}

// The preview pane at the top of the guide. Tap it to show or hide its
// controls: mute, volume, full screen and close. Full screen only happens
// from its button, never from tapping the picture.
class _LivePreview extends StatefulWidget {
  const _LivePreview({
    required this.channel,
    required this.video,
    required this.program,
    required this.muted,
    required this.volume,
    required this.failed,
    required this.error,
    required this.onToggleMute,
    required this.onVolume,
    required this.onExpand,
    required this.onClose,
    required this.onRetry,
  });
  final IptvItem channel;
  final VideoController? video;
  final EpgProgram? program;
  final bool muted;
  final double volume;
  final bool failed;
  final String error;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolume;
  final VoidCallback onExpand;
  final VoidCallback onClose;
  final VoidCallback onRetry;

  @override
  State<_LivePreview> createState() => _LivePreviewState();
}

class _LivePreviewState extends State<_LivePreview> {
  bool _controls = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(_LivePreview old) {
    super.didUpdateWidget(old);
    // New channel: show the controls briefly again.
    if (old.channel.id != widget.channel.id) {
      setState(() => _controls = true);
      _scheduleHide();
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted && !widget.failed) setState(() => _controls = false);
    });
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    if (_controls) _scheduleHide();
  }

  // Any control use keeps them on screen a bit longer.
  VoidCallback _keep(VoidCallback action) => () {
        action();
        _scheduleHide();
      };

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final video = widget.video;
    final accent = Theme.of(context).colorScheme.primary;
    final showControls = _controls || widget.failed;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.failed ? null : _toggleControls,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF0E0F12)),
              if (video != null && !widget.failed)
                IgnorePointer(child: Video(controller: video, controls: NoVideoControls, fill: Colors.black, wakelock: false)),
              if (widget.failed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 48, 20, 16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Couldn\'t play ${channel.name}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (widget.error.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Flexible(
                          child: SingleChildScrollView(
                            child: SelectableText(widget.error, textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 11, height: 1.3)),
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      OutlinedButton.icon(onPressed: widget.onRetry, icon: const Icon(Icons.refresh, size: 18), label: const Text('Try Again')),
                    ],
                  ),
                ),
              // Caption over a soft gradient.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: widget.failed ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(14, 28, 14, 12),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black.withValues(alpha: .75)],
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.program == null ? channel.name : 'Now On: ${widget.program!.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                            ),
                          ),
                          if (channel.logo != null)
                            Opacity(
                              opacity: .55,
                              child: SizedBox(
                                width: 54,
                                height: 24,
                                child: SinemaImage(imageUrl: channel.logo!, fit: BoxFit.contain, errorWidget: (_, _, _) => const SizedBox.shrink()),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Controls.
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !showControls,
                  child: AnimatedOpacity(
                    opacity: showControls ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(6, 6, 6, 18),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.black.withValues(alpha: .6), Colors.transparent],
                          ),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: _keep(widget.onToggleMute),
                              icon: Icon(widget.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
                              tooltip: widget.muted ? 'Unmute' : 'Mute',
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                ),
                                child: Slider(
                                  value: widget.muted ? 0 : widget.volume.clamp(0, 100).toDouble(),
                                  max: 100,
                                  activeColor: accent,
                                  inactiveColor: Colors.white24,
                                  onChanged: (v) {
                                    widget.onVolume(v);
                                    _scheduleHide();
                                  },
                                ),
                              ),
                            ),
                            IconButton(onPressed: widget.onExpand, icon: const Icon(Icons.open_in_full_rounded), tooltip: 'Full screen'),
                            IconButton(onPressed: widget.onClose, icon: const Icon(Icons.close_rounded), tooltip: 'Close preview'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- What's On

// What's on right now, as rows of cards: your favourites first, then by the
// guide's categories (Sports, News, Movies…) or, without those, by channel
// group. Tap a card to watch.
class _WhatsOnTab extends StatelessWidget {
  const _WhatsOnTab();

  static const _maxRows = 14;
  static const _maxPerRow = 30;

  @override
  Widget build(BuildContext context) {
    final repo = IptvRepository.instance;
    final now = DateTime.now();
    final airing = <(IptvItem, EpgProgram)>[];
    for (final c in repo.liveChannels) {
      if (repo.isLocked(c)) continue;
      final p = repo.nowPlaying(c, now);
      if (p != null) airing.add((c, p));
    }
    if (airing.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            repo.hasGuide ? 'Nothing on the guide right now.' : 'What\'s On needs a TV guide. Add an EPG (XMLTV) URL to your playlist.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, height: 1.4),
          ),
        ),
      );
    }
    final rows = <String, List<(IptvItem, EpgProgram)>>{};
    final favorites = airing.where((e) => repo.isFavorite(e.$1)).toList();
    if (favorites.isNotEmpty) rows['Your Favorites'] = favorites;
    final recentIds = {for (final c in repo.recentChannels) c.id};
    final recent = airing.where((e) => recentIds.contains(e.$1.id)).toList();
    if (recent.isNotEmpty) rows['Recently Watched'] = recent;
    final byCategory = <String, List<(IptvItem, EpgProgram)>>{};
    final withCategory = airing.where((e) => e.$2.category != null).length;
    final useCategories = withCategory > airing.length / 4;
    for (final e in airing) {
      final key = useCategories ? (e.$2.category ?? 'More') : e.$1.group;
      (byCategory[key] ??= []).add(e);
    }
    final biggest = byCategory.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final e in biggest) {
      if (rows.length >= _maxRows) break;
      rows.putIfAbsent(e.key, () => e.value);
    }
    final allChannels = repo.liveChannels;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        for (final row in rows.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
            child: Text(row.key, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          ),
          SizedBox(
            height: 196,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: row.value.length > _maxPerRow ? _maxPerRow : row.value.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final (channel, program) = row.value[index];
                return _OnNowCard(
                  channel: channel,
                  program: program,
                  now: now,
                  onTap: () => _play(context, allChannels, allChannels.indexOf(channel)),
                  onLongPress: () => _showProgram(context, channel, program, allChannels),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _OnNowCard extends StatelessWidget {
  const _OnNowCard({required this.channel, required this.program, required this.now, required this.onTap, required this.onLongPress});
  final IptvItem channel;
  final EpgProgram program;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final logoArt = Container(
      color: const Color(0xFF1E2025),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(28),
      child: _ChannelLogo(channel: channel, width: 120, height: 64),
    );
    return SizedBox(
      width: 220,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 220,
                height: 124,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    program.icon == null
                        ? logoArt
                        : SinemaImage(imageUrl: program.icon!, fit: BoxFit.cover, memCacheWidth: 660, errorWidget: (_, _, _) => logoArt),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(value: program.progressAt(now), minHeight: 3, color: accent, backgroundColor: Colors.black45),
                    ),
                    if (program.icon != null && channel.logo != null)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                          child: _ChannelLogo(channel: channel, width: 40, height: 18),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(program.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              '${channel.number != null ? '${channel.number} · ' : ''}${channel.name} · ${_timeLeft(program, now)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: _muted),
            ),
          ],
        ),
      ),
    );
  }
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
