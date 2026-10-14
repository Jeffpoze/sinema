import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SortOption {
  releaseNewest,
  releaseOldest,
  ratingHighToLow,
  criticRatingHighToLow,
  aToZ,
  zToA,
  year,
  contentRating,
  unwatchedFirst,
  dateAdded,
  dateWatched,
  random,
}

extension SortOptionLabel on SortOption {
  String get label => switch (this) {
        SortOption.releaseNewest => 'Release Date (Newest)',
        SortOption.releaseOldest => 'Release Date (Oldest)',
        SortOption.ratingHighToLow => 'Audience Rating',
        SortOption.criticRatingHighToLow => 'Critic Rating',
        SortOption.aToZ => 'A-Z',
        SortOption.zToA => 'Z-A',
        SortOption.year => 'Year',
        SortOption.contentRating => 'Content Rating',
        SortOption.unwatchedFirst => 'Unwatched',
        SortOption.dateAdded => 'Date Added',
        SortOption.dateWatched => 'Date Watched',
        SortOption.random => 'Randomly',
      };

  String get jellyfinSortBy => switch (this) {
        SortOption.releaseNewest || SortOption.releaseOldest => 'PremiereDate,SortName',
        SortOption.ratingHighToLow => 'CommunityRating,SortName',
        SortOption.criticRatingHighToLow => 'CriticRating,SortName',
        SortOption.aToZ || SortOption.zToA => 'SortName',
        SortOption.year => 'ProductionYear,SortName',
        SortOption.contentRating => 'OfficialRating,SortName',
        SortOption.unwatchedFirst => 'IsPlayed,SortName',
        SortOption.dateAdded => 'DateCreated,SortName',
        SortOption.dateWatched => 'DatePlayed,SortName',
        SortOption.random => 'Random',
      };

  String get jellyfinSortOrder => switch (this) {
        SortOption.releaseOldest || SortOption.aToZ || SortOption.contentRating || SortOption.unwatchedFirst => 'Ascending',
        SortOption.releaseNewest ||
        SortOption.ratingHighToLow ||
        SortOption.criticRatingHighToLow ||
        SortOption.zToA ||
        SortOption.year ||
        SortOption.dateAdded ||
        SortOption.dateWatched ||
        SortOption.random =>
          'Descending',
      };
}

// Session-only (not persisted) — filter state resets when you switch
// categories or restart the app, same as most library browsers.
class LibraryFilter {
  const LibraryFilter({this.genre, this.year, this.officialRating, this.studioId, this.studioName, this.personId, this.personName, this.unwatchedOnly = false});
  final String? genre;
  final int? year;
  final String? officialRating;
  final String? studioId;
  final String? studioName;
  final String? personId;
  final String? personName;
  final bool unwatchedOnly;

  bool get isActive => genre != null || year != null || officialRating != null || studioId != null || personId != null || unwatchedOnly;

  String get label {
    if (genre != null) return genre!;
    if (year != null) return '$year';
    if (officialRating != null) return officialRating!;
    if (studioName != null) return studioName!;
    if (personName != null) return personName!;
    if (unwatchedOnly) return 'Unwatched';
    return 'All';
  }
}

class AccentColorOption {
  const AccentColorOption(this.name, this.color);
  final String name;
  final Color color;
}

const accentColorOptions = [
  AccentColorOption('Crimson', Color(0xFFE53935)),
  AccentColorOption('Azure', Color(0xFF2196F3)),
  AccentColorOption('Emerald', Color(0xFF2E7D32)),
  AccentColorOption('Violet', Color(0xFF8E24AA)),
  AccentColorOption('Amber', Color(0xFFFF9800)),
  AccentColorOption('Teal', Color(0xFF00897B)),
  AccentColorOption('Rose', Color(0xFFEC407A)),
  AccentColorOption('Silver', Color(0xFFB0BEC5)),
];

const skipIntervalOptions = [5, 10, 15, 30, 60];

/// Kept as plain strings (not the player's StreamQuality enum) so this file
/// doesn't need to depend on player_screen.dart.
const defaultQualityOptions = ['original', 'high', 'medium', 'low'];

extension DefaultQualityLabel on String {
  String get qualityLabel => switch (this) {
        'high' => 'High (8 Mbps)',
        'medium' => 'Medium (4 Mbps)',
        'low' => 'Low (1.5 Mbps)',
        _ => 'Original',
      };
}

class SettingsController extends ChangeNotifier {
  static const _accentColorKey = 'settings.accentColor';
  static const _categorySortPrefix = 'settings.sort.';
  static const _skipSecondsKey = 'settings.skipSeconds';
  static const _defaultQualityKey = 'settings.defaultQuality';
  static const _omdbApiKeyKey = 'settings.omdbApiKey';
  static const _tmdbApiKeyKey = 'settings.tmdbApiKey';
  static const _sonarrUrlKey = 'settings.sonarrUrl';
  static const _sonarrApiKeyKey = 'settings.sonarrApiKey';
  static const _radarrUrlKey = 'settings.radarrUrl';
  static const _radarrApiKeyKey = 'settings.radarrApiKey';
  static const _themeMusicKey = 'settings.themeMusic';
  static const _autoPlayNextKey = 'settings.autoPlayNext';
  static const _autoSkipIntroKey = 'settings.autoSkipIntro';

  Color _accentColor = accentColorOptions.first.color;
  Color get accentColor => _accentColor;

  int _skipSeconds = 15;
  int get skipSeconds => _skipSeconds;

  String _defaultQuality = 'original';
  String get defaultQuality => _defaultQuality;

  // Plays an item's theme song quietly on its detail page, like Plex.
  bool _themeMusic = true;
  bool get themeMusic => _themeMusic;

  // Counts down and starts the next episode during the credits.
  bool _autoPlayNext = true;
  bool get autoPlayNext => _autoPlayNext;

  // Jumps past intros/recaps without needing a tap on Skip.
  bool _autoSkipIntro = false;
  bool get autoSkipIntro => _autoSkipIntro;

  // Free key from omdbapi.com — used to fetch a real IMDb rating (and a
  // Rotten Tomatoes critic score, where OMDB has one) client-side, since
  // Jellyfin's own CommunityRating is normally just whatever its TMDB
  // provider set. Stored locally only; never hardcoded into source since
  // this repo is public.
  String _omdbApiKey = '';
  String get omdbApiKey => _omdbApiKey;

  // Free key from themoviedb.org — used to fetch real network logos
  // (Netflix, Apple TV+, etc.) at runtime for the Networks screen and home
  // banner. Real logo artwork can't be redistributed in this public repo,
  // but fetching it live from TMDB's own image CDN, the way it's meant to
  // be used, is fine. Stored locally only.
  String _tmdbApiKey = '';
  String get tmdbApiKey => _tmdbApiKey;

  // Each user's own Sonarr/Radarr instance — entered per-device in Settings,
  // never bundled with the app. Powers the Calendar screen with real
  // "unaired" schedule data that Jellyfin, a pure media server, has no
  // concept of (it only knows about files that already exist).
  String _sonarrUrl = '';
  String get sonarrUrl => _sonarrUrl;
  String _sonarrApiKey = '';
  String get sonarrApiKey => _sonarrApiKey;
  String _radarrUrl = '';
  String get radarrUrl => _radarrUrl;
  String _radarrApiKey = '';
  String get radarrApiKey => _radarrApiKey;

  final Map<String, SortOption> _categorySort = {};

  SortOption sortFor(String categoryId) => _categorySort[categoryId] ?? SortOption.releaseNewest;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final storedColor = prefs.getInt(_accentColorKey);
    if (storedColor != null) _accentColor = Color(storedColor);
    final storedSkip = prefs.getInt(_skipSecondsKey);
    if (storedSkip != null && skipIntervalOptions.contains(storedSkip)) _skipSeconds = storedSkip;
    final storedQuality = prefs.getString(_defaultQualityKey);
    if (storedQuality != null && defaultQualityOptions.contains(storedQuality)) _defaultQuality = storedQuality;
    _themeMusic = prefs.getBool(_themeMusicKey) ?? true;
    _autoPlayNext = prefs.getBool(_autoPlayNextKey) ?? true;
    _autoSkipIntro = prefs.getBool(_autoSkipIntroKey) ?? false;
    _omdbApiKey = prefs.getString(_omdbApiKeyKey) ?? '';
    _tmdbApiKey = prefs.getString(_tmdbApiKeyKey) ?? '';
    _sonarrUrl = prefs.getString(_sonarrUrlKey) ?? '';
    _sonarrApiKey = prefs.getString(_sonarrApiKeyKey) ?? '';
    _radarrUrl = prefs.getString(_radarrUrlKey) ?? '';
    _radarrApiKey = prefs.getString(_radarrApiKeyKey) ?? '';
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_categorySortPrefix)) continue;
      final id = key.substring(_categorySortPrefix.length);
      final value = prefs.getString(key);
      final match = SortOption.values.where((o) => o.name == value);
      if (match.isNotEmpty) _categorySort[id] = match.first;
    }
    notifyListeners();
  }

  Future<void> setAccentColor(Color color) async {
    _accentColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_accentColorKey, color.toARGB32());
  }

  Future<void> setSkipSeconds(int seconds) async {
    _skipSeconds = seconds;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_skipSecondsKey, seconds);
  }

  Future<void> setDefaultQuality(String quality) async {
    _defaultQuality = quality;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_defaultQualityKey, quality);
  }

  Future<void> setThemeMusic(bool value) async {
    _themeMusic = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themeMusicKey, value);
  }

  Future<void> setAutoPlayNext(bool value) async {
    _autoPlayNext = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPlayNextKey, value);
  }

  Future<void> setAutoSkipIntro(bool value) async {
    _autoSkipIntro = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSkipIntroKey, value);
  }

  Future<void> setOmdbApiKey(String key) async {
    _omdbApiKey = key;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_omdbApiKeyKey, key);
  }

  Future<void> setTmdbApiKey(String key) async {
    _tmdbApiKey = key;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tmdbApiKeyKey, key);
  }

  Future<void> setSonarrUrl(String url) async {
    _sonarrUrl = url;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sonarrUrlKey, url);
  }

  Future<void> setSonarrApiKey(String key) async {
    _sonarrApiKey = key;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sonarrApiKeyKey, key);
  }

  Future<void> setRadarrUrl(String url) async {
    _radarrUrl = url;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_radarrUrlKey, url);
  }

  Future<void> setRadarrApiKey(String key) async {
    _radarrApiKey = key;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_radarrApiKeyKey, key);
  }

  Future<void> setSortFor(String categoryId, SortOption option) async {
    _categorySort[categoryId] = option;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_categorySortPrefix$categoryId', option.name);
  }
}
