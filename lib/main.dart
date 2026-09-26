// ignore_for_file: avoid_print

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calendar_screen.dart';
import 'detail_screen.dart';
import 'player_screen.dart';
import 'services/jellyfin_api_service.dart';
import 'settings_controller.dart';
import 'networks_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsController();
  await settings.load();
  final savedSession = await _loadSavedSession();
  runApp(SinemaApp(settings: settings, initialSession: savedSession));
}

Future<JellyfinSession?> _loadSavedSession() async {
  final prefs = await SharedPreferences.getInstance();
  final serverUrl = prefs.getString('serverUrl');
  final userId = prefs.getString('userId');
  final token = prefs.getString('accessToken');
  final username = prefs.getString('username');
  if (serverUrl == null || userId == null || token == null || username == null)
    return null;
  return JellyfinSession(
    serverUrl: serverUrl,
    userId: userId,
    token: token,
    username: username,
  );
}

class SinemaApp extends StatelessWidget {
  const SinemaApp({
    super.key,
    required this.settings,
    this.initialSession,
  });
  final SettingsController settings;
  final JellyfinSession? initialSession;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF090A0C);
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => MaterialApp(
        title: 'Sinema',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: background,
          colorScheme: ColorScheme.dark(
            primary: settings.accentColor,
            surface: const Color(0xFF141518),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF191A1E),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: settings.accentColor.withValues(alpha: .8),
              ),
            ),
            labelStyle: const TextStyle(color: Color(0xFFA5A7AC)),
          ),
          textTheme: ThemeData.dark().textTheme.apply(
            bodyColor: Colors.white,
            displayColor: Colors.white,
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: settings.accentColor,
              foregroundColor: Colors.white,
            ),
          ),
        ),
        home: initialSession != null
            ? HomePage(session: initialSession!, settings: settings)
            : AuthenticationScreen(settings: settings),
      ),
    );
  }
}

class AuthenticationScreen extends StatefulWidget {
  const AuthenticationScreen({super.key, required this.settings});
  final SettingsController settings;
  @override
  State<AuthenticationScreen> createState() => _AuthenticationScreenState();
}

class _AuthenticationScreenState extends State<AuthenticationScreen> {
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _api = JellyfinApiService();
  bool _isLoading = false;
  bool _rememberMe = true;
  bool _obscurePassword = true;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final session = await _api.login(
        serverUrl: _serverController.text,
        username: _usernameController.text,
        password: _passwordController.text,
      );
      final prefs = await SharedPreferences.getInstance();
      if (_rememberMe) {
        await prefs.setString('serverUrl', session.serverUrl);
        await prefs.setString('userId', session.userId);
        await prefs.setString('accessToken', session.token);
        await prefs.setString('username', session.username);
      } else {
        await prefs.remove('serverUrl');
        await prefs.remove('userId');
        await prefs.remove('accessToken');
        await prefs.remove('username');
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => HomePage(session: session, settings: widget.settings),
        ),
      );
    } catch (_) {
      if (mounted)
        setState(
          () => _error =
              'We could not connect. Check your details and try again.',
        );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ListView(
            shrinkWrap: true,
            children: [
              Image.asset('assets/images/logo_mark.png', width: 88, height: 88),
              const SizedBox(height: 24),
              Text(
                'Welcome to Sinema.',
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Connect your Jellyfin server to begin.',
                style: TextStyle(color: Color(0xFFA5A7AC)),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _serverController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Jellyfin Server URL',
                  hintText: 'https://jellyfin.example.com',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: const Color(0xFFA5A7AC),
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                value: _rememberMe,
                onChanged: (value) =>
                    setState(() => _rememberMe = value ?? true),
                title: const Text('Remember me'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80))),
              ],
              const SizedBox(height: 24),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _isLoading ? null : _signIn,
                  child: _isLoading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Sign In'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.session, required this.settings});
  final JellyfinSession session;
  final SettingsController settings;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _api = JellyfinApiService();
  List<dynamic> _continueWatching = const [];
  List<dynamic> _libraryViews = const [];
  Map<String, List<dynamic>> _categoryItems = {};
  List<dynamic> _featuredItems = const [];
  String? _featuredNetworkName;
  Timer? _featuredRotationTimer;
  String? _selectedCategoryId;
  bool _isLoadingContinueWatching = true;
  bool _isLoadingFeaturedItems = true;
  final Set<String> _loadingCategoryIds = {};
  List<dynamic> _selectedCategoryItems = const [];
  bool _isLoadingSelectedCategory = false;
  LibraryFilter? _selectedCategoryFilter;

  @override
  void initState() {
    super.initState();
    _loadHomeSections();
    // Re-pick the banner's featured network every 30 minutes so the
    // homepage doesn't show the same "Top 10" while the app stays open.
    _featuredRotationTimer = Timer.periodic(const Duration(minutes: 30), (_) => _loadFeaturedItems());
  }

  @override
  void dispose() {
    _featuredRotationTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadHomeSections() async {
    // Each row should become usable as soon as its request completes. The
    // previous two-stage Future.wait held the whole homepage hostage to the
    // slowest section, then started every library request at once.
    _loadContinueWatching();
    _loadFeaturedItems();
    final libraryViews = await _loadSection(
      'library views',
      () => _api.getLibraryViews(
        widget.session.serverUrl,
        widget.session.userId,
        widget.session.token,
      ),
    );
    if (!mounted) return;
    final categoryIds = libraryViews
        .whereType<Map<String, dynamic>>()
        .map((view) => view['Id'] as String?)
        .whereType<String>()
        .toList();
    setState(() {
      _libraryViews = libraryViews;
      _loadingCategoryIds.addAll(categoryIds);
    });
    _loadCategoryRows(categoryIds);
  }

  Future<void> _loadContinueWatching() async {
    final items = await _loadSection(
      'continue watching',
      () => _api.getContinueWatching(
        widget.session.serverUrl,
        widget.session.userId,
        widget.session.token,
      ),
    );
    if (!mounted) return;
    setState(() {
      _continueWatching = items;
      _isLoadingContinueWatching = false;
    });
  }

  Future<void> _loadFeaturedItems() async {
    final network = await _pickRotatingNetwork();
    List<dynamic> items = const [];
    if (network != null) {
      items = await _loadSection(
        'featured items for ${network['name']}',
        () => _api.getTopItemsForStudio(
          widget.session.serverUrl,
          widget.session.userId,
          widget.session.token,
          network['id'] as String,
        ),
      );
    }
    // Fall back to plain latest-additions when there's no recognized
    // network in the library yet, or that network has nothing with a
    // backdrop image to show.
    if (items.isEmpty) {
      items = await _loadSection(
        'featured items',
        () => _api.getFeaturedItems(
          widget.session.serverUrl,
          widget.session.userId,
          widget.session.token,
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _featuredItems = items;
      _featuredNetworkName = items.isEmpty ? null : network?['name'] as String?;
      _isLoadingFeaturedItems = false;
    });
  }

  // Deterministic on a 30-minute clock bucket, so every device rotates
  // through the same network at the same time instead of re-randomizing
  // on every reload within that window.
  Future<Map<String, dynamic>?> _pickRotatingNetwork() async {
    final studios = await _loadSection(
      'network studios',
      () => _api.getStudios(widget.session.serverUrl, widget.session.userId, widget.session.token),
    );
    final networks = studios.whereType<Map<String, dynamic>>().where((s) {
      final name = s['Name'] as String?;
      return name != null && looksLikeNetwork(name);
    }).toList()
      ..sort((a, b) => ((a['Name'] as String?) ?? '').compareTo((b['Name'] as String?) ?? ''));
    if (networks.isEmpty) return null;
    final bucket = DateTime.now().millisecondsSinceEpoch ~/ const Duration(minutes: 30).inMilliseconds;
    final chosen = networks[bucket % networks.length];
    return {'id': chosen['Id'] as String, 'name': chosen['Name'] as String};
  }

  Future<void> _loadCategoryRows(List<String> categoryIds) async {
    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < categoryIds.length) {
        final id = categoryIds[nextIndex++];
        final items = await _loadSection(
          'category $id',
          () => _api.getRecentItemsForView(
            widget.session.serverUrl,
            widget.session.userId,
            widget.session.token,
            id,
          ),
        );
        if (!mounted) return;
        setState(() {
          _categoryItems = {..._categoryItems, id: items};
          _loadingCategoryIds.remove(id);
        });
      }
    }

    // Parent-art lookups make a category request more expensive than it first
    // appears. Three workers keep the server responsive for video playback.
    await Future.wait(
      List.generate(categoryIds.length.clamp(0, 3), (_) => worker()),
    );
  }

  Future<List<dynamic>> _loadSection(
    String name,
    Future<List<dynamic>> Function() load,
  ) async {
    try {
      return await load();
    } catch (e) {
      print('Failed to load $name: $e');
      return const [];
    }
  }

  void _selectCategory(String? id) {
    Navigator.of(context).pop();
    setState(() {
      _selectedCategoryId = id;
      _selectedCategoryFilter = null;
    });
    if (id != null) _loadSelectedCategory(id);
  }

  Future<void> _loadSelectedCategory(String id) async {
    setState(() => _isLoadingSelectedCategory = true);
    final sort = widget.settings.sortFor(id);
    final filter = _selectedCategoryFilter;
    final view = _libraryViews.whereType<Map<String, dynamic>>().firstWhere((v) => v['Id'] == id, orElse: () => const {});
    final collectionType = view['CollectionType'] as String?;
    final items = await _loadSection(
      'selected category $id',
      () => _api.getLibraryItems(
        widget.session.serverUrl,
        widget.session.userId,
        widget.session.token,
        id,
        sort: sort,
        filter: filter,
        collectionType: collectionType,
      ),
    );
    if (!mounted || _selectedCategoryId != id) return;
    setState(() {
      _selectedCategoryItems = items;
      _isLoadingSelectedCategory = false;
    });
  }

  void _changeSort(SortOption option) {
    final id = _selectedCategoryId;
    if (id == null) return;
    widget.settings.setSortFor(id, option);
    _loadSelectedCategory(id);
  }

  Future<void> _openFilterSheet() async {
    final id = _selectedCategoryId;
    if (id == null) return;
    final filter = await showModalBottomSheet<LibraryFilter>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0A0B0D),
      builder: (context) => _LibraryFilterSheet(
        serverUrl: widget.session.serverUrl,
        userId: widget.session.userId,
        token: widget.session.token,
        viewId: id,
        current: _selectedCategoryFilter,
      ),
    );
    if (filter == null) return;
    setState(() => _selectedCategoryFilter = filter.isActive ? filter : null);
    _loadSelectedCategory(id);
  }

  void _openSettings() {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SettingsScreen(settings: widget.settings, session: widget.session),
      ),
    );
  }

  void _openCalendar() {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CalendarScreen(
          serverUrl: widget.session.serverUrl,
          userId: widget.session.userId,
          token: widget.session.token,
          settings: widget.settings,
        ),
      ),
    );
  }

  void _openNetworks() {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NetworksScreen(session: widget.session, settings: widget.settings)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedCategoryId == null
        ? null
        : _libraryViews.whereType<Map<String, dynamic>>().firstWhere(
            (view) => view['Id'] == _selectedCategoryId,
            orElse: () => const {},
          );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          selected != null && selected['Name'] is String
              ? (selected['Name'] as String).toUpperCase()
              : 'SINEMA',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.8,
          ),
        ),
        leading: Builder(
          builder: (context) => IconButton(
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu),
          ),
        ),
        actions: [
          if (_selectedCategoryId != null)
            IconButton(
              icon: Icon(Icons.filter_list, color: _selectedCategoryFilter != null ? Theme.of(context).colorScheme.primary : null),
              onPressed: _openFilterSheet,
            ),
          if (_selectedCategoryId != null)
            PopupMenuButton<SortOption>(
              icon: const Icon(Icons.sort),
              onSelected: _changeSort,
              itemBuilder: (context) => [
                for (final option in SortOption.values)
                  PopupMenuItem(value: option, child: Text(option.label)),
              ],
            ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SearchScreen(session: widget.session, settings: widget.settings)),
            ),
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      drawer: _CategoryDrawer(
        libraryViews: _libraryViews,
        selectedId: _selectedCategoryId,
        onSelect: _selectCategory,
        onSettings: _openSettings,
        onCalendar: _openCalendar,
        onNetworks: _openNetworks,
      ),
      body: _selectedCategoryId == null
          ? ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _isLoadingFeaturedItems
                    ? const _HeroPlaceholder()
                    : _HeroCarousel(
                        items: _featuredItems,
                        networkName: _featuredNetworkName,
                        serverUrl: widget.session.serverUrl,
                        userId: widget.session.userId,
                        token: widget.session.token,
                        settings: widget.settings,
                      ),
                _MediaRow(
                  title: 'Continue Watching',
                  serverUrl: widget.session.serverUrl,
                  userId: widget.session.userId,
                  token: widget.session.token,
                  items: _continueWatching,
                  isLoading: _isLoadingContinueWatching,
                  settings: widget.settings,
                ),
                for (final view
                    in _libraryViews.whereType<Map<String, dynamic>>())
                  if (view['Id'] is String)
                    _MediaRow(
                      title: (view['Name'] as String?) ?? 'Library',
                      serverUrl: widget.session.serverUrl,
                      userId: widget.session.userId,
                      token: widget.session.token,
                      items: _categoryItems[view['Id']] ?? const [],
                      isLoading: _loadingCategoryIds.contains(view['Id']),
                      settings: widget.settings,
                    ),
              ],
            )
          : _CategoryGrid(
              items: _selectedCategoryItems,
              serverUrl: widget.session.serverUrl,
              userId: widget.session.userId,
              token: widget.session.token,
              isLoading: _isLoadingSelectedCategory,
              settings: widget.settings,
            ),
    );
  }
}

class _CategoryDrawer extends StatelessWidget {
  const _CategoryDrawer({
    required this.libraryViews,
    required this.selectedId,
    required this.onSelect,
    required this.onSettings,
    required this.onCalendar,
    required this.onNetworks,
  });
  final List<dynamic> libraryViews;
  final String? selectedId;
  final void Function(String?) onSelect;
  final VoidCallback onSettings;
  final VoidCallback onCalendar;
  final VoidCallback onNetworks;

  @override
  Widget build(BuildContext context) => Drawer(
    backgroundColor: const Color(0xFF0D0E11),
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Text(
              'CATEGORIES',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                color: Color(0xFFA5A7AC),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Home'),
            selected: selectedId == null,
            selectedTileColor: const Color(0xFF1B1D22),
            onTap: () => onSelect(null),
          ),
          for (final view in libraryViews.whereType<Map<String, dynamic>>())
            if (view['Id'] is String)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text((view['Name'] as String?) ?? 'Library'),
                selected: selectedId == view['Id'],
                selectedTileColor: const Color(0xFF1B1D22),
                onTap: () => onSelect(view['Id'] as String),
              ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Divider(color: Color(0xFF1B1D22)),
          ),
          ListTile(
            leading: const Icon(Icons.calendar_today_outlined),
            title: const Text('Calendar'),
            onTap: onCalendar,
          ),
          ListTile(
            leading: const Icon(Icons.live_tv_outlined),
            title: const Text('Networks'),
            onTap: onNetworks,
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: onSettings,
          ),
        ],
      ),
    ),
  );
}

class _CategoryGrid extends StatelessWidget {
  const _CategoryGrid({
    required this.items,
    required this.serverUrl,
    required this.userId,
    required this.token,
    required this.isLoading,
    required this.settings,
  });
  final List<dynamic> items;
  final String serverUrl;
  final String userId;
  final String token;
  final bool isLoading;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    if (isLoading) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty)
      return const Center(
        child: Text(
          'Nothing here yet.',
          style: TextStyle(color: Color(0xFFA5A7AC)),
        ),
      );
    return _ScrubbableGrid(items: items, serverUrl: serverUrl, userId: userId, token: token, settings: settings);
  }
}

// A right-edge drag strip that jumps the grid to a proportional position and
// shows the current row's leading letter in a floating bubble while
// dragging — same pattern as Contacts' A-Z index, but position-based rather
// than a real per-letter index (works regardless of current sort order).
class _ScrubbableGrid extends StatefulWidget {
  const _ScrubbableGrid({required this.items, required this.serverUrl, required this.userId, required this.token, required this.settings});
  final List<dynamic> items;
  final String serverUrl;
  final String userId;
  final String token;
  final SettingsController settings;

  @override
  State<_ScrubbableGrid> createState() => _ScrubbableGridState();
}

class _ScrubbableGridState extends State<_ScrubbableGrid> {
  static const _crossAxisCount = 3;
  static const _mainAxisSpacing = 16.0;
  static const _crossAxisSpacing = 12.0;
  static const _childAspectRatio = 0.66;
  static const _padding = 16.0;

  final _scrollController = ScrollController();
  double? _dragFraction;
  String? _dragLetter;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _letterFor(int index) {
    final item = widget.items[index];
    final name = item is Map<String, dynamic> ? item['Name'] as String? : null;
    if (name == null || name.isEmpty) return '#';
    final letter = name[0].toUpperCase();
    return RegExp(r'[A-Z]').hasMatch(letter) ? letter : '#';
  }

  double _rowHeightFor(double width) {
    final gridWidth = width - _padding * 2;
    final itemWidth = (gridWidth - _crossAxisSpacing * (_crossAxisCount - 1)) / _crossAxisCount;
    final itemHeight = itemWidth / _childAspectRatio;
    return itemHeight + _mainAxisSpacing;
  }

  void _onDrag(double localY, double stripHeight, double width) {
    final fraction = (localY / stripHeight).clamp(0.0, 1.0);
    final index = (fraction * (widget.items.length - 1)).round().clamp(0, widget.items.length - 1);
    final rowHeight = _rowHeightFor(width);
    final row = index ~/ _crossAxisCount;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final targetOffset = (row * rowHeight).clamp(0.0, maxScroll);
    _scrollController.jumpTo(targetOffset);
    setState(() {
      _dragFraction = fraction;
      _dragLetter = _letterFor(index);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Stack(
      children: [
        GridView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(_padding),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _crossAxisCount,
            mainAxisSpacing: _mainAxisSpacing,
            crossAxisSpacing: _crossAxisSpacing,
            childAspectRatio: _childAspectRatio,
          ),
          itemCount: widget.items.length,
          itemBuilder: (_, index) => ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: MediaPoster(
              item: widget.items[index],
              serverUrl: widget.serverUrl,
              userId: widget.userId,
              token: widget.token,
              fill: true,
              settings: widget.settings,
            ),
          ),
        ),
        if (widget.items.length > 12)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 28,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (details) => _onDrag(details.localPosition.dy, constraints.maxHeight, constraints.maxWidth),
              onVerticalDragUpdate: (details) => _onDrag(details.localPosition.dy, constraints.maxHeight, constraints.maxWidth),
              onVerticalDragEnd: (_) => setState(() {
                _dragFraction = null;
                _dragLetter = null;
              }),
              child: _dragFraction == null
                  ? const SizedBox.expand()
                  : Container(
                      margin: const EdgeInsets.symmetric(vertical: 40),
                      decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(14)),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Icon(Icons.keyboard_arrow_up, size: 18, color: Colors.white70)),
                          Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Icon(Icons.keyboard_arrow_down, size: 18, color: Colors.white70)),
                        ],
                      ),
                    ),
            ),
          ),
        if (_dragFraction != null && _dragLetter != null)
          Positioned(
            right: 44,
            top: (_dragFraction! * (constraints.maxHeight - 64)).clamp(0.0, constraints.maxHeight - 64),
            child: Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
              child: Text(_dragLetter!, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700)),
            ),
          ),
      ],
    ),
  );
}

class _HeroPlaceholder extends StatelessWidget {
  const _HeroPlaceholder();
  @override
  Widget build(BuildContext context) => Container(
    height: 390,
    margin: const EdgeInsets.fromLTRB(16, 8, 16, 28),
    decoration: BoxDecoration(
      color: const Color(0xFF181A1E),
      borderRadius: BorderRadius.circular(10),
    ),
    child: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.play_circle_outline, size: 56, color: Colors.white70),
          SizedBox(height: 12),
          Text(
            'Your featured story',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 6),
          Text(
            'Trailers will play here',
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    ),
  );
}

class _HeroCarousel extends StatefulWidget {
  const _HeroCarousel({
    required this.items,
    this.networkName,
    required this.serverUrl,
    required this.userId,
    required this.token,
    required this.settings,
  });
  final List<dynamic> items;
  final String? networkName;
  final String serverUrl;
  final String userId;
  final String token;
  final SettingsController settings;

  @override
  State<_HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<_HeroCarousel> {
  final _controller = PageController();
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    if (widget.items.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 7), (_) {
        if (!mounted) return;
        final next = (_page + 1) % widget.items.length;
        _controller.animateToPage(
          next,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items.whereType<Map<String, dynamic>>().toList();
    if (items.isEmpty) return const _HeroPlaceholder();
    return SizedBox(
      height: 390,
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: items.length,
            onPageChanged: (index) => setState(() => _page = index),
            itemBuilder: (context, index) => _HeroCard(
              item: items[index],
              networkName: widget.networkName,
              serverUrl: widget.serverUrl,
              userId: widget.userId,
              token: widget.token,
              settings: widget.settings,
            ),
          ),
          if (items.length > 1)
            Positioned(
              bottom: 12,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < items.length; i++)
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _page ? Colors.white : Colors.white30,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.item,
    this.networkName,
    required this.serverUrl,
    required this.userId,
    required this.token,
    required this.settings,
  });
  final Map<String, dynamic> item;
  final String? networkName;
  final String serverUrl;
  final String userId;
  final String token;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final itemId = item['Id'] as String?;
    final name = item['Name'] as String? ?? 'Untitled';
    final overview = item['Overview'] as String?;
    final backdropTag = (item['BackdropImageTags'] as List<dynamic>?)
        ?.whereType<String>()
        .firstOrNull;
    final backdropUrl = itemId != null && backdropTag != null
        ? JellyfinApiService.getBackdropUrl(
            serverUrl,
            itemId,
            imageTag: backdropTag,
            maxWidth: 1200,
          )
        : null;
    final isMovie = item['Type'] == 'Movie';

    return GestureDetector(
      onTap: itemId == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DetailScreen(
                  serverUrl: serverUrl,
                  userId: userId,
                  token: token,
                  itemId: itemId,
                  settings: settings,
                ),
              ),
            ),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: const Color(0xFF181A1E),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (backdropUrl != null)
              CachedNetworkImage(
                imageUrl: backdropUrl,
                httpHeaders: JellyfinApiService.authHeaders(token),
                fit: BoxFit.cover,
                memCacheWidth: 1200,
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xFF090A0C)],
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 44,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (networkName != null) ...[
                    Text(
                      'TOP 10 ON ${networkName!.toUpperCase()}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: Color(0xFFCACBCF),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (overview != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      overview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFCACBCF)),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (isMovie)
                    SizedBox(
                      height: 40,
                      child: FilledButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlayerScreen(
                              title: name,
                              serverUrl: serverUrl,
                              userId: userId,
                              token: token,
                              itemId: itemId!,
                              settings: settings,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.play_arrow, size: 20),
                        label: const Text('Play'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaRow extends StatelessWidget {
  const _MediaRow({
    required this.title,
    required this.serverUrl,
    required this.userId,
    required this.token,
    required this.items,
    required this.isLoading,
    required this.settings,
  });
  final String title;
  final String serverUrl;
  final String userId;
  final String token;
  final List<dynamic> items;
  final bool isLoading;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 246,
          child: isLoading || items.isEmpty
              ? ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: 5,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (_, index) => _PosterPlaceholder(index: index),
                )
              : ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: items.length,
                  itemBuilder: (_, index) => MediaPoster(
                    item: items[index],
                    serverUrl: serverUrl,
                    userId: userId,
                    token: token,
                    settings: settings,
                  ),
                ),
        ),
      ],
    ),
  );
}

class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder({required this.index});
  final int index;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 132,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: Container(
            decoration: BoxDecoration(
              color: Color(0xFF17191D + (index * 0x020202)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(
              Icons.movie_outlined,
              color: Colors.white24,
              size: 32,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(height: 12, width: 96, color: const Color(0xFF17191D)),
        const SizedBox(height: 6),
        Container(height: 10, width: 60, color: const Color(0xFF17191D)),
      ],
    ),
  );
}

class MediaPoster extends StatelessWidget {
  const MediaPoster({
    required this.item,
    required this.serverUrl,
    required this.userId,
    required this.token,
    required this.settings,
    this.fill = false,
  });
  final dynamic item;
  final String serverUrl;
  final String userId;
  final String token;
  final SettingsController settings;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    if (item is! Map<String, dynamic>)
      return _DarkPosterPlaceholder(fill: fill);
    final (posterItemId, imageTag) = _posterImage(item);
    final Widget content;
    if (posterItemId == null || imageTag == null || imageTag.isEmpty) {
      content = _DarkPosterPlaceholder(fill: fill);
    } else {
      final imageUrl = JellyfinApiService.getImageUrl(
        serverUrl,
        posterItemId,
        imageTag: imageTag,
        maxWidth: 400,
      );
      content = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CachedNetworkImage(
          imageUrl: imageUrl,
          httpHeaders: JellyfinApiService.authHeaders(token),
          fit: BoxFit.cover,
          memCacheWidth: 400,
          placeholder: (_, _) => _DarkPosterPlaceholder(fill: fill),
          errorWidget: (_, _, _) => _DarkPosterPlaceholder(fill: fill),
        ),
      );
    }

    final navigableId = _navigableItemId(item);
    final unwatchedCount = _unwatchedCount(item);
    final badged = Stack(
      children: [
        Positioned.fill(child: content),
        if (unwatchedCount != null && unwatchedCount > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              constraints: const BoxConstraints(minWidth: 20),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$unwatchedCount',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
    final poster = AspectRatio(aspectRatio: 2 / 3, child: badged);
    final tappable = GestureDetector(
      onTap: navigableId == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DetailScreen(
                  serverUrl: serverUrl,
                  userId: userId,
                  token: token,
                  itemId: navigableId,
                  settings: settings,
                ),
              ),
            ),
      child: fill
          ? poster
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                poster,
                const SizedBox(height: 8),
                Text(
                  item['Name'] as String? ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_yearInfo(item) != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    _yearInfo(item)!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFA5A7AC),
                    ),
                  ),
                ],
              ],
            ),
    );
    if (fill) return tappable;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: SizedBox(width: 132, child: tappable),
    );
  }

  String? _yearInfo(Map<String, dynamic> item) {
    final year = item['ProductionYear'];
    if (year == null) return null;
    if (item['Type'] == 'Series') {
      final status = item['Status'] as String?;
      final endDate = item['EndDate'] as String?;
      if (status != 'Continuing' && endDate is String) {
        final endYear = DateTime.tryParse(endDate)?.year;
        if (endYear != null) return '$year - $endYear';
      }
      return '$year - Present';
    }
    return '$year';
  }

  int? _unwatchedCount(Map<String, dynamic> item) {
    if (item['Type'] != 'Series') return null;
    final userData = item['UserData'];
    if (userData is! Map) return null;
    final count = userData['UnplayedItemCount'];
    return count is num ? count.toInt() : null;
  }

  String? _navigableItemId(Map<String, dynamic> item) {
    if (item['Type'] == 'Episode') return item['SeriesId'] as String?;
    return item['Id'] as String?;
  }

  (String?, String?) _posterImage(Map<String, dynamic> item) {
    // Episodes carry their own screenshot as PrimaryImageTag, but browsing rows
    // should show the show's poster, not a random episode still.
    if (item['Type'] == 'Episode') {
      final seriesTag = item['SeriesPrimaryImageTag'];
      final seriesId = item['SeriesId'];
      if (seriesTag is String && seriesTag.isNotEmpty && seriesId is String)
        return (seriesId, seriesTag);
    }
    final itemId = item['Id'] as String?;
    final primaryTag = item['PrimaryImageTag'];
    if (primaryTag is String && primaryTag.isNotEmpty)
      return (itemId, primaryTag);
    final imageTags = item['ImageTags'];
    if (imageTags is Map && imageTags['Primary'] is String)
      return (itemId, imageTags['Primary'] as String);
    final seriesTag = item['SeriesPrimaryImageTag'];
    final seriesId = item['SeriesId'];
    if (seriesTag is String && seriesTag.isNotEmpty && seriesId is String)
      return (seriesId, seriesTag);
    // Audio tracks usually carry no image of their own; fall back to the album's art.
    final albumTag = item['AlbumPrimaryImageTag'];
    final albumId = item['AlbumId'];
    if (albumTag is String && albumTag.isNotEmpty && albumId is String)
      return (albumId, albumTag);
    return (null, null);
  }
}

class _DarkPosterPlaceholder extends StatelessWidget {
  const _DarkPosterPlaceholder({this.fill = false});
  final bool fill;

  @override
  Widget build(BuildContext context) => Container(
    width: fill ? null : 132,
    color: const Color(0xFF17191D),
    child: const Icon(Icons.movie_outlined, color: Colors.white24, size: 32),
  );
}

enum _FilterCategory { none, genre, year, contentRating, studio, director, actor, writer, producer }

class _LibraryFilterSheet extends StatefulWidget {
  const _LibraryFilterSheet({required this.serverUrl, required this.userId, required this.token, required this.viewId, required this.current});
  final String serverUrl;
  final String userId;
  final String token;
  final String viewId;
  final LibraryFilter? current;

  @override
  State<_LibraryFilterSheet> createState() => _LibraryFilterSheetState();
}

class _LibraryFilterSheetState extends State<_LibraryFilterSheet> {
  final _api = JellyfinApiService();
  _FilterCategory _view = _FilterCategory.none;
  Map<String, dynamic>? _filterOptions;
  List<dynamic>? _studios;
  List<dynamic>? _persons;
  bool _loadingSub = false;

  Future<void> _ensureFilterOptions(_FilterCategory view) async {
    setState(() => _view = view);
    if (_filterOptions != null) return;
    setState(() => _loadingSub = true);
    final data = await _api.getLibraryFilterOptions(widget.serverUrl, widget.userId, widget.token, widget.viewId);
    if (mounted) setState(() { _filterOptions = data; _loadingSub = false; });
  }

  Future<void> _loadStudios() async {
    setState(() { _view = _FilterCategory.studio; _loadingSub = true; });
    final data = await _api.getStudios(widget.serverUrl, widget.userId, widget.token, widget.viewId);
    if (mounted) setState(() { _studios = data; _loadingSub = false; });
  }

  Future<void> _loadPersons(_FilterCategory view, String personType) async {
    setState(() { _view = view; _loadingSub = true; _persons = null; });
    final data = await _api.getPersons(widget.serverUrl, widget.userId, widget.token, widget.viewId, personType);
    if (mounted) setState(() { _persons = data; _loadingSub = false; });
  }

  void _select(LibraryFilter filter) => Navigator.of(context).pop(filter);

  Widget _header(String title, {VoidCallback? onBack}) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 20, 8),
        child: Row(children: [
          if (onBack != null) IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: onBack) else const SizedBox(width: 48),
          Expanded(child: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
          const SizedBox(width: 48),
        ]),
      );

  Widget _valueList(List<String> values, LibraryFilter Function(String) makeFilter) {
    if (_loadingSub) return const Expanded(child: Center(child: CircularProgressIndicator()));
    if (values.isEmpty) return const Expanded(child: Center(child: Text('Nothing to filter by here.', style: TextStyle(color: Color(0xFFA5A7AC)))));
    return Expanded(
      child: ListView(children: [for (final v in values) ListTile(title: Text(v), onTap: () => _select(makeFilter(v)))]),
    );
  }

  Widget _personList(List<dynamic> persons, LibraryFilter Function(String id, String name) makeFilter) {
    if (_loadingSub) return const Expanded(child: Center(child: CircularProgressIndicator()));
    final list = persons.whereType<Map<String, dynamic>>().toList();
    if (list.isEmpty) return const Expanded(child: Center(child: Text('Nothing to filter by here.', style: TextStyle(color: Color(0xFFA5A7AC)))));
    return Expanded(
      child: ListView(
        children: [
          for (final person in list)
            ListTile(
              title: Text((person['Name'] as String?) ?? ''),
              onTap: () {
                final id = person['Id'] as String?;
                final name = person['Name'] as String?;
                if (id != null && name != null) _select(makeFilter(id, name));
              },
            ),
        ],
      ),
    );
  }

  Widget _studioList() {
    if (_loadingSub) return const Expanded(child: Center(child: CircularProgressIndicator()));
    final list = (_studios ?? const []).whereType<Map<String, dynamic>>().toList();
    if (list.isEmpty) return const Expanded(child: Center(child: Text('Nothing to filter by here.', style: TextStyle(color: Color(0xFFA5A7AC)))));
    return Expanded(
      child: ListView(
        children: [
          for (final studio in list)
            ListTile(
              title: Text((studio['Name'] as String?) ?? ''),
              onTap: () {
                final id = studio['Id'] as String?;
                final name = studio['Name'] as String?;
                if (id != null && name != null) _select(LibraryFilter(studioId: id, studioName: name));
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final genres = (_filterOptions?['Genres'] as List<dynamic>?)?.whereType<String>().toList() ?? const [];
    final years = (_filterOptions?['Years'] as List<dynamic>?)?.map((y) => '$y').toList() ?? const [];
    final officialRatings = (_filterOptions?['OfficialRatings'] as List<dynamic>?)?.whereType<String>().toList() ?? const [];

    final body = switch (_view) {
      _FilterCategory.none => Expanded(
          child: ListView(
            children: [
              ListTile(title: const Text('All'), trailing: widget.current == null || !widget.current!.isActive ? const Icon(Icons.check) : null, onTap: () => _select(const LibraryFilter())),
              ListTile(title: const Text('Unwatched'), trailing: widget.current?.unwatchedOnly == true ? const Icon(Icons.check) : null, onTap: () => _select(const LibraryFilter(unwatchedOnly: true))),
              const Divider(height: 1, color: Color(0xFF1B1D22)),
              ListTile(title: const Text('Genre'), trailing: const Icon(Icons.chevron_right), onTap: () => _ensureFilterOptions(_FilterCategory.genre)),
              ListTile(title: const Text('Year'), trailing: const Icon(Icons.chevron_right), onTap: () => _ensureFilterOptions(_FilterCategory.year)),
              ListTile(title: const Text('Content Rating'), trailing: const Icon(Icons.chevron_right), onTap: () => _ensureFilterOptions(_FilterCategory.contentRating)),
              ListTile(title: const Text('Studio'), trailing: const Icon(Icons.chevron_right), onTap: _loadStudios),
              ListTile(title: const Text('Director'), trailing: const Icon(Icons.chevron_right), onTap: () => _loadPersons(_FilterCategory.director, 'Director')),
              ListTile(title: const Text('Actor'), trailing: const Icon(Icons.chevron_right), onTap: () => _loadPersons(_FilterCategory.actor, 'Actor')),
              ListTile(title: const Text('Writer'), trailing: const Icon(Icons.chevron_right), onTap: () => _loadPersons(_FilterCategory.writer, 'Writer')),
              ListTile(title: const Text('Producer'), trailing: const Icon(Icons.chevron_right), onTap: () => _loadPersons(_FilterCategory.producer, 'Producer')),
            ],
          ),
        ),
      _FilterCategory.genre => _valueList(genres, (v) => LibraryFilter(genre: v)),
      _FilterCategory.year => _valueList(years, (v) => LibraryFilter(year: int.tryParse(v))),
      _FilterCategory.contentRating => _valueList(officialRatings, (v) => LibraryFilter(officialRating: v)),
      _FilterCategory.studio => _studioList(),
      _FilterCategory.director => _personList(_persons ?? const [], (id, name) => LibraryFilter(personId: id, personName: name)),
      _FilterCategory.actor => _personList(_persons ?? const [], (id, name) => LibraryFilter(personId: id, personName: name)),
      _FilterCategory.writer => _personList(_persons ?? const [], (id, name) => LibraryFilter(personId: id, personName: name)),
      _FilterCategory.producer => _personList(_persons ?? const [], (id, name) => LibraryFilter(personId: id, personName: name)),
    };

    final title = switch (_view) {
      _FilterCategory.none => 'Filter by',
      _FilterCategory.genre => 'Genre',
      _FilterCategory.year => 'Year',
      _FilterCategory.contentRating => 'Content Rating',
      _FilterCategory.studio => 'Studio',
      _FilterCategory.director => 'Director',
      _FilterCategory.actor => 'Actor',
      _FilterCategory.writer => 'Writer',
      _FilterCategory.producer => 'Producer',
    };

    return SizedBox(
      height: MediaQuery.of(context).size.height * .75,
      child: SafeArea(
        child: Column(
          children: [
            Container(width: 38, height: 4, margin: const EdgeInsets.only(top: 10), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4))),
            _header(title, onBack: _view == _FilterCategory.none ? null : () => setState(() => _view = _FilterCategory.none)),
            body,
          ],
        ),
      ),
    );
  }
}
