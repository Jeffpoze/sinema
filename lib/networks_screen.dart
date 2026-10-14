import 'package:flutter/material.dart';

import 'main.dart';
import 'services/jellyfin_api_service.dart';
import 'settings_controller.dart';
import 'tmdb_service.dart';
import 'widgets/sinema_image.dart';

// Jellyfin has no distinct "Network" concept — the distributing network
// (Netflix, Apple TV+, …) and a production studio both just land in the
// same Studios list. Server-wide Studios includes plenty of production
// companies (A24, Bones, Legendary…) that aren't what "network browsing"
// means here, so this filters down to recognizable streaming/broadcast
// networks by name rather than showing every studio.
const knownNetworkPatterns = [
  'netflix',
  'apple tv',
  'prime video',
  'amazon',
  'disney',
  'hulu',
  'hbo',
  'max',
  'paramount',
  'peacock',
  'crunchyroll',
  'funimation',
  'showtime',
  'starz',
  'fx',
  'amc',
  'bbc',
  'itv',
  'adult swim',
  'cartoon network',
  'nickelodeon',
  'youtube',
  'tubi',
  'crackle',
  'britbox',
];

bool looksLikeNetwork(String name) {
  final lower = name.toLowerCase();
  return knownNetworkPatterns.any((pattern) => lower.contains(pattern));
}

// Real logo artwork is trademarked and Jellyfin rarely has studio images
// populated anyway (confirmed empty for this server) — brand-colored tiles
// are the same approach already used for the IMDb/TVDB rating badges:
// recognizable without redistributing anyone's actual logo files.
class _NetworkBrand {
  const _NetworkBrand(this.background, this.foreground);
  final Color background;
  final Color foreground;
}

const _networkBrands = <String, _NetworkBrand>{
  'netflix': _NetworkBrand(Color(0xFFE50914), Colors.white),
  'apple tv': _NetworkBrand(Colors.black, Colors.white),
  'prime video': _NetworkBrand(Color(0xFF00A8E1), Colors.white),
  'amazon': _NetworkBrand(Color(0xFF00A8E1), Colors.white),
  'disney': _NetworkBrand(Color(0xFF113CCF), Colors.white),
  'hulu': _NetworkBrand(Color(0xFF1CE783), Colors.black),
  'max': _NetworkBrand(Color(0xFF002BE7), Colors.white),
  'hbo': _NetworkBrand(Color(0xFF5B21B6), Colors.white),
  'paramount': _NetworkBrand(Color(0xFF0064FF), Colors.white),
  'peacock': _NetworkBrand(Colors.black, Colors.white),
  'crunchyroll': _NetworkBrand(Color(0xFFF47521), Colors.black),
  'funimation': _NetworkBrand(Color(0xFF6F1AB1), Colors.white),
  'showtime': _NetworkBrand(Color(0xFFB1060F), Colors.white),
  'starz': _NetworkBrand(Colors.black, Colors.white),
  'fx': _NetworkBrand(Colors.black, Colors.white),
  'amc': _NetworkBrand(Colors.black, Color(0xFFE4002B)),
  'bbc': _NetworkBrand(Colors.black, Colors.white),
  'itv': _NetworkBrand(Color(0xFF6E00FF), Colors.white),
  'adult swim': _NetworkBrand(Colors.black, Color(0xFFFFE400)),
  'cartoon network': _NetworkBrand(Colors.black, Colors.white),
  'nickelodeon': _NetworkBrand(Color(0xFFF36C21), Colors.white),
  'youtube': _NetworkBrand(Color(0xFFFF0000), Colors.white),
  'tubi': _NetworkBrand(Color(0xFF7A2FE0), Colors.white),
  'crackle': _NetworkBrand(Color(0xFFF77E0B), Colors.black),
  'britbox': _NetworkBrand(Color(0xFF002B5C), Colors.white),
};

_NetworkBrand? _brandFor(String name) {
  final lower = name.toLowerCase();
  for (final entry in _networkBrands.entries) {
    if (lower.contains(entry.key)) return entry.value;
  }
  return null;
}

String? _tmdbKeyFor(String name) {
  final lower = name.toLowerCase();
  for (final key in tmdbNetworkIds.keys) {
    if (lower.contains(key)) return key;
  }
  return null;
}

class NetworksScreen extends StatefulWidget {
  const NetworksScreen({super.key, required this.session, required this.settings});
  final JellyfinSession session;
  final SettingsController settings;

  @override
  State<NetworksScreen> createState() => _NetworksScreenState();
}

class _NetworksScreenState extends State<NetworksScreen> {
  final _api = JellyfinApiService();
  List<dynamic>? _networks;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final studios = await _api.getStudios(widget.session.serverUrl, widget.session.userId, widget.session.token);
    final networks = studios.whereType<Map<String, dynamic>>().where((s) {
      final name = s['Name'] as String?;
      return name != null && looksLikeNetwork(name);
    }).toList()
      ..sort((a, b) => ((a['Name'] as String?) ?? '').compareTo((b['Name'] as String?) ?? ''));
    if (mounted) setState(() => _networks = networks);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('NETWORKS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
    body: _networks == null
        ? const Center(child: CircularProgressIndicator())
        : _networks!.isEmpty
            ? const Center(child: Text('No recognized networks found in your library.', style: TextStyle(color: Color(0xFFA5A7AC))))
            : GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1.8,
                ),
                itemCount: _networks!.length,
                itemBuilder: (context, index) {
                  final network = _networks![index] as Map<String, dynamic>;
                  return _NetworkTile(network: network, session: widget.session, settings: widget.settings);
                },
              ),
  );
}

class _NetworkTile extends StatefulWidget {
  const _NetworkTile({required this.network, required this.session, required this.settings});
  final Map<String, dynamic> network;
  final JellyfinSession session;
  final SettingsController settings;

  @override
  State<_NetworkTile> createState() => _NetworkTileState();
}

class _NetworkTileState extends State<_NetworkTile> {
  String? _tmdbLogoUrl;

  String? get _jellyfinImageUrl {
    final id = widget.network['Id'] as String?;
    final tag = widget.network['ImageTags'] is Map ? (widget.network['ImageTags'] as Map)['Primary'] as String? : null;
    return id != null && tag != null ? JellyfinApiService.getImageUrl(widget.session.serverUrl, id, imageTag: tag, maxWidth: 400) : null;
  }

  @override
  void initState() {
    super.initState();
    // Jellyfin's own studio image always wins when present — only fall
    // back to a live TMDB logo lookup when there isn't one.
    if (_jellyfinImageUrl == null && widget.settings.tmdbApiKey.isNotEmpty) {
      final name = (widget.network['Name'] as String?) ?? '';
      final key = _tmdbKeyFor(name);
      if (key != null) {
        TmdbService.logoUrlForNetworkKey(widget.settings.tmdbApiKey, key).then((url) {
          if (mounted && url != null) setState(() => _tmdbLogoUrl = url);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.network['Id'] as String?;
    final name = (widget.network['Name'] as String?) ?? 'Network';
    final imageUrl = _jellyfinImageUrl;
    final brand = _brandFor(name);

    // Real logo artwork is often a plain black or white wordmark that needs
    // a guaranteed-light background to stay legible (e.g. AMC's black
    // wordmark would vanish on AMC's own black brand tile) — so any actual
    // logo image sits on a white badge, while the tile itself keeps the
    // brand color behind it instead of going flat white everywhere.
    final hasLogoImage = imageUrl != null || _tmdbLogoUrl != null;

    Widget imageFor(String url, {bool useAuthHeaders = false}) => SinemaImage(
          imageUrl: url,
          httpHeaders: useAuthHeaders ? JellyfinApiService.authHeaders(widget.session.token) : null,
          fit: BoxFit.contain,
          errorWidget: (_, _, _) => Text(name, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, color: brand?.foreground ?? Colors.white)),
        );

    final logoUrl = imageUrl ?? _tmdbLogoUrl;

    return GestureDetector(
      onTap: id == null
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => NetworkItemsScreen(session: widget.session, settings: widget.settings, studioId: id, studioName: name)),
              ),
      child: Container(
        decoration: BoxDecoration(color: const Color(0xFF1B1D22), borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.all(16),
        alignment: Alignment.center,
        child: hasLogoImage
            ? FractionallySizedBox(
                widthFactor: 0.82,
                heightFactor: 0.62,
                child: Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  alignment: Alignment.center,
                  child: imageFor(logoUrl!, useAuthHeaders: imageUrl != null),
                ),
              )
            : Text(name, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: brand?.foreground ?? Colors.white, letterSpacing: .5)),
      ),
    );
  }
}

class NetworkItemsScreen extends StatefulWidget {
  const NetworkItemsScreen({super.key, required this.session, required this.settings, required this.studioId, required this.studioName});
  final JellyfinSession session;
  final SettingsController settings;
  final String studioId;
  final String studioName;

  @override
  State<NetworkItemsScreen> createState() => _NetworkItemsScreenState();
}

class _NetworkItemsScreenState extends State<NetworkItemsScreen> {
  final _api = JellyfinApiService();
  List<dynamic>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _api.getItemsByStudio(widget.session.serverUrl, widget.session.userId, widget.session.token, widget.studioId);
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.studioName.toUpperCase(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.8))),
    body: _items == null
        ? const Center(child: CircularProgressIndicator())
        : _items!.isEmpty
            ? const Center(child: Text('Nothing here yet.', style: TextStyle(color: Color(0xFFA5A7AC))))
            : GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.66,
                ),
                itemCount: _items!.length,
                itemBuilder: (context, index) => ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: MediaPoster(
                    item: _items![index],
                    serverUrl: widget.session.serverUrl,
                    userId: widget.session.userId,
                    token: widget.session.token,
                    fill: true,
                    settings: widget.settings,
                  ),
                ),
              ),
  );
}
