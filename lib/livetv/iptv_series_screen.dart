import 'package:flutter/material.dart';

import '../widgets/sinema_image.dart';
import 'iptv_models.dart';
import 'iptv_parsers.dart' show stableId;
import 'iptv_player_screen.dart';
import 'iptv_repository.dart';

// Seasons and episodes for an IPTV series. Xtream episodes are fetched from
// the provider when opened; M3U episodes are already in the playlist.
class IptvSeriesScreen extends StatefulWidget {
  const IptvSeriesScreen({super.key, required this.show});
  final IptvItem show;

  @override
  State<IptvSeriesScreen> createState() => _IptvSeriesScreenState();
}

class _IptvSeriesScreenState extends State<IptvSeriesScreen> {
  final _repo = IptvRepository.instance;
  List<IptvEpisode> _episodes = const [];
  bool _loading = true;
  String? _error;
  int? _season;

  static final _episodePattern = RegExp(r'\bS(\d{1,2})\s*[._ -]?\s*E(\d{1,3})\b', caseSensitive: false);

  String get _title => widget.show.seriesName ?? widget.show.name;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<IptvEpisode> episodes;
      if (widget.show.seriesId != null) {
        episodes = await _repo.xtreamEpisodes(widget.show);
      } else {
        episodes = [
          for (final item in _repo.m3uEpisodesFor(widget.show))
            () {
              final match = _episodePattern.firstMatch(item.name);
              return IptvEpisode(
                title: item.name,
                season: int.tryParse(match?.group(1) ?? '') ?? 1,
                episode: int.tryParse(match?.group(2) ?? '') ?? 0,
                url: item.url,
                image: item.logo,
              );
            }(),
        ]..sort((a, b) => a.season != b.season ? a.season.compareTo(b.season) : a.episode.compareTo(b.episode));
      }
      if (!mounted) return;
      setState(() {
        _episodes = episodes;
        _season = episodes.isEmpty ? null : episodes.first.season;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Couldn\'t load episodes.';
        });
      }
    }
  }

  void _playEpisode(List<IptvEpisode> seasonEpisodes, int index) {
    // Hand the player the rest of the season so it can be stepped through.
    final items = [
      for (final e in seasonEpisodes)
        IptvItem(
          id: stableId(widget.show.sourceId, e.url),
          sourceId: widget.show.sourceId,
          kind: IptvKind.movie,
          name: _title,
          group: widget.show.group,
          url: e.url,
          logo: widget.show.logo,
        ),
    ];
    final e = seasonEpisodes[index];
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => IptvPlayerScreen(items: items, initialIndex: index, subtitle: 'S${e.season}:E${e.episode} - ${e.title}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final seasons = _episodes.map((e) => e.season).toSet().toList()..sort();
    final seasonEpisodes = _episodes.where((e) => e.season == _season).toList();
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _repo,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              onPressed: () => _repo.toggleFavorite(widget.show),
              icon: Icon(_repo.isFavorite(widget.show) ? Icons.star_rounded : Icons.star_outline_rounded, color: _repo.isFavorite(widget.show) ? accent : null),
              tooltip: 'Favorite',
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 110,
                      height: 165,
                      child: widget.show.logo == null
                          ? const ColoredBox(color: Color(0xFF17191D))
                          : SinemaImage(imageUrl: widget.show.logo!, fit: BoxFit.cover, memCacheWidth: 330, errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF17191D))),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(
                          [widget.show.group, if (widget.show.year != null) widget.show.year!, if (widget.show.rating != null && widget.show.rating != '0') '★ ${widget.show.rating}'].join(' · '),
                          style: const TextStyle(color: Color(0xFFA5A7AC)),
                        ),
                        if (widget.show.plot != null) ...[
                          const SizedBox(height: 10),
                          Text(widget.show.plot!, maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(height: 1.4, fontSize: 13)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_loading)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Text(_error!, style: const TextStyle(color: Color(0xFFA5A7AC))),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              )
            else if (_episodes.isEmpty)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No episodes found.', style: TextStyle(color: Color(0xFFA5A7AC)))))
            else ...[
              if (seasons.length > 1)
                SizedBox(
                  height: 48,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: seasons.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final season = seasons[index];
                      final selected = season == _season;
                      return ChoiceChip(
                        label: Text('Season $season'),
                        selected: selected,
                        showCheckmark: false,
                        selectedColor: accent,
                        backgroundColor: const Color(0xFF1B1D22),
                        side: BorderSide.none,
                        onSelected: (_) => setState(() => _season = season),
                      );
                    },
                  ),
                ),
              for (var i = 0; i < seasonEpisodes.length; i++)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 96,
                      height: 54,
                      child: seasonEpisodes[i].image == null
                          ? const ColoredBox(color: Color(0xFF17191D), child: Icon(Icons.play_arrow, color: Colors.white38))
                          : SinemaImage(imageUrl: seasonEpisodes[i].image!, fit: BoxFit.cover, memCacheWidth: 288, errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF17191D))),
                    ),
                  ),
                  title: Text(
                    seasonEpisodes[i].episode > 0 ? '${seasonEpisodes[i].episode}. ${seasonEpisodes[i].title}' : seasonEpisodes[i].title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  subtitle: seasonEpisodes[i].duration == null ? null : Text(seasonEpisodes[i].duration!, style: const TextStyle(color: Color(0xFFA5A7AC), fontSize: 12)),
                  onTap: () => _playEpisode(seasonEpisodes, i),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
