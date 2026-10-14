import 'dart:async';

import 'package:flutter/material.dart';

import 'detail_screen.dart';
import 'services/jellyfin_api_service.dart';
import 'settings_controller.dart';
import 'widgets/sinema_image.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.session, required this.settings});
  final JellyfinSession session;
  final SettingsController settings;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with SingleTickerProviderStateMixin {
  final _api = JellyfinApiService();
  final _controller = TextEditingController();
  Timer? _debounce;
  List<dynamic> _results = const [];
  bool _isLoading = false;
  String? _error;
  late TabController _tabController = TabController(length: 1, vsync: this);
  List<String> _tabs = const ['Top Results'];

  void _onChanged(String query) {
    _debounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _results = const [];
        _isLoading = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(trimmed));
  }

  Future<void> _search(String query) async {
    _debounce?.cancel();
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await _api.searchItems(widget.session.serverUrl, widget.session.userId, widget.session.token, query);
      if (!mounted || _controller.text.trim() != query) return;
      final tabs = ['Top Results'];
      if (results.whereType<Map<String, dynamic>>().any((r) => r['Type'] == 'Series')) tabs.add('Shows');
      if (results.whereType<Map<String, dynamic>>().any((r) => r['Type'] == 'Movie')) tabs.add('Movies');
      if (results.whereType<Map<String, dynamic>>().any((r) => r['Type'] == 'BoxSet')) tabs.add('Collections');
      if (results.whereType<Map<String, dynamic>>().any((r) => r['Type'] == 'Episode')) tabs.add('Episodes');
      if (results.whereType<Map<String, dynamic>>().any((r) => r['Type'] == 'Audio' || r['Type'] == 'MusicAlbum')) tabs.add('Music');
      setState(() {
        _results = results;
        _isLoading = false;
        _tabs = tabs;
        _tabController.dispose();
        _tabController = TabController(length: tabs.length, vsync: this);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Search failed.\n$e';
          _isLoading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> _resultsFor(String tab) {
    final all = _results.whereType<Map<String, dynamic>>().toList();
    return switch (tab) {
      'Top Results' => all.take(24).toList(),
      'Shows' => all.where((r) => r['Type'] == 'Series').toList(),
      'Movies' => all.where((r) => r['Type'] == 'Movie').toList(),
      'Collections' => all.where((r) => r['Type'] == 'BoxSet').toList(),
      'Episodes' => all.where((r) => r['Type'] == 'Episode').toList(),
      'Music' => all.where((r) => r['Type'] == 'Audio' || r['Type'] == 'MusicAlbum').toList(),
      _ => all,
    };
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: _onChanged,
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) _search(value.trim());
        },
        style: const TextStyle(color: Colors.white),
        // Pill-shaped, matching the web app's search field.
        decoration: InputDecoration(
          hintText: 'Search movies, shows, music…',
          hintStyle: const TextStyle(color: Color(0xFFA5A7AC)),
          prefixIcon: const Icon(Icons.search, color: Color(0xFFA5A7AC), size: 20),
          isDense: true,
          filled: true,
          fillColor: const Color(0xFF191A1E),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: .8)),
          ),
        ),
      ),
      actions: [
        if (_controller.text.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () {
              _controller.clear();
              _onChanged('');
            },
          ),
      ],
      bottom: _results.isEmpty
          ? null
          : TabBar(controller: _tabController, isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final tab in _tabs) Tab(text: tab)]),
    ),
    body: _isLoading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: const TextStyle(color: Color(0xFFA5A7AC)))))
            : _results.isEmpty
                ? Center(
                    child: Text(
                      _controller.text.trim().isEmpty ? 'Search your library.' : 'No results.',
                      style: const TextStyle(color: Color(0xFFA5A7AC)),
                    ),
                  )
                : TabBarView(
                    controller: _tabController,
                    children: [
                      for (final tab in _tabs)
                        GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 16,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.6,
                          ),
                          itemCount: _resultsFor(tab).length,
                          itemBuilder: (context, index) => _SearchResultTile(
                            item: _resultsFor(tab)[index],
                            serverUrl: widget.session.serverUrl,
                            userId: widget.session.userId,
                            token: widget.session.token,
                            settings: widget.settings,
                          ),
                        ),
                    ],
                  ),
  );
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({required this.item, required this.serverUrl, required this.userId, required this.token, required this.settings});
  final Map<String, dynamic> item;
  final String serverUrl;
  final String userId;
  final String token;
  final SettingsController settings;

  String get _typeLabel => switch (item['Type']) {
        'Series' => 'Series',
        'Movie' => 'Movie',
        'Episode' => 'Episode',
        'BoxSet' => 'Collection',
        'Audio' => 'Song',
        'MusicAlbum' => 'Album',
        _ => '',
      };

  String? get _yearLabel {
    final year = item['ProductionYear'];
    if (year == null) return null;
    if (item['Type'] == 'Series') {
      final status = item['Status'] as String?;
      final endYear = (item['EndDate'] as String?)?.split('-').firstOrNull;
      if (status == 'Continuing') return '$year – Present';
      if (endYear != null && endYear != '$year') return '$year – $endYear';
    }
    return '$year';
  }

  @override
  Widget build(BuildContext context) {
    final navigableId = item['Type'] == 'Episode' ? (item['SeriesId'] as String? ?? item['Id'] as String?) : item['Id'] as String?;
    final tag = item['PrimaryImageTag'] as String? ??
        item['SeriesPrimaryImageTag'] as String? ??
        item['AlbumPrimaryImageTag'] as String? ??
        (item['ImageTags'] is Map ? (item['ImageTags'] as Map)['Primary'] as String? : null);
    final imageItemId = item['Type'] == 'Episode' ? (item['SeriesId'] as String? ?? item['Id'] as String?) : item['Id'] as String?;
    final imageUrl = imageItemId != null && tag != null ? JellyfinApiService.getImageUrl(serverUrl, imageItemId, imageTag: tag, maxWidth: 400) : null;
    final name = item['Type'] == 'Episode' ? (item['SeriesName'] as String? ?? item['Name'] as String? ?? '') : (item['Name'] as String? ?? '');

    return GestureDetector(
      onTap: navigableId == null
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DetailScreen(serverUrl: serverUrl, userId: userId, token: token, itemId: navigableId, settings: settings)),
              ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: imageUrl == null
                  ? const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.movie_outlined, color: Colors.white24))
                  : SinemaImage(imageUrl: imageUrl, httpHeaders: JellyfinApiService.authHeaders(token), fit: BoxFit.cover, memCacheWidth: 400, errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF17191D))),
            ),
          ),
          const SizedBox(height: 8),
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            [_typeLabel, if (_yearLabel != null) _yearLabel!].join(' • '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Color(0xFFA5A7AC)),
          ),
        ],
      ),
    );
  }
}
