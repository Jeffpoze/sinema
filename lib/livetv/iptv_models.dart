// Plain data types for the Live TV section. Everything here round-trips
// through JSON so playlists and guides can be cached on disk and parsed in a
// background isolate.

enum IptvSourceType { m3u, xtream }

class IptvSource {
  const IptvSource({
    required this.id,
    required this.name,
    required this.type,
    required this.url,
    this.username = '',
    this.password = '',
    this.epgUrl = '',
    this.userAgent = '',
  });

  final String id;
  final String name;
  final IptvSourceType type;
  // M3U: the playlist URL. Xtream: the server address (http://host:port).
  final String url;
  final String username;
  final String password;
  // Optional XMLTV guide. For Xtream it defaults to the provider's own.
  final String epgUrl;
  final String userAgent;

  String get serverBase => url.trim().replaceFirst(RegExp(r'/+$'), '');

  String get effectiveEpgUrl {
    if (epgUrl.trim().isNotEmpty) return epgUrl.trim();
    if (type == IptvSourceType.xtream) {
      return '$serverBase/xmltv.php?username=${Uri.encodeQueryComponent(username)}&password=${Uri.encodeQueryComponent(password)}';
    }
    return '';
  }

  Map<String, String> get headers => userAgent.trim().isEmpty ? const {} : {'User-Agent': userAgent.trim()};

  IptvSource copyWith({String? name, IptvSourceType? type, String? url, String? username, String? password, String? epgUrl, String? userAgent}) => IptvSource(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
        epgUrl: epgUrl ?? this.epgUrl,
        userAgent: userAgent ?? this.userAgent,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'url': url,
        'username': username,
        'password': password,
        'epgUrl': epgUrl,
        'userAgent': userAgent,
      };

  static IptvSource fromJson(Map<String, dynamic> json) => IptvSource(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? 'Playlist',
        type: json['type'] == 'xtream' ? IptvSourceType.xtream : IptvSourceType.m3u,
        url: (json['url'] as String?) ?? '',
        username: (json['username'] as String?) ?? '',
        password: (json['password'] as String?) ?? '',
        epgUrl: (json['epgUrl'] as String?) ?? '',
        userAgent: (json['userAgent'] as String?) ?? '',
      );
}

enum IptvKind { live, movie, series }

// One playable entry: a live channel, a movie, or (for Xtream) a series
// whose episodes are fetched on demand. For M3U series, each episode is its
// own entry and [seriesName] groups them.
class IptvItem {
  const IptvItem({
    required this.id,
    required this.sourceId,
    required this.kind,
    required this.name,
    required this.group,
    this.url = '',
    this.logo,
    this.epgId,
    this.number,
    this.seriesId,
    this.seriesName,
    this.plot,
    this.rating,
    this.year,
  });

  final String id;
  final String sourceId;
  final IptvKind kind;
  final String name;
  final String group;
  final String url;
  final String? logo;
  final String? epgId;
  final int? number;
  final String? seriesId;
  final String? seriesName;
  final String? plot;
  final String? rating;
  final String? year;

  Map<String, dynamic> toJson() => {
        'i': id,
        's': sourceId,
        'k': kind.index,
        'n': name,
        'g': group,
        if (url.isNotEmpty) 'u': url,
        if (logo != null) 'l': logo,
        if (epgId != null) 'e': epgId,
        if (number != null) 'c': number,
        if (seriesId != null) 'si': seriesId,
        if (seriesName != null) 'sn': seriesName,
        if (plot != null) 'p': plot,
        if (rating != null) 'r': rating,
        if (year != null) 'y': year,
      };

  static IptvItem fromJson(Map<String, dynamic> j) => IptvItem(
        id: j['i'] as String,
        sourceId: j['s'] as String,
        kind: IptvKind.values[(j['k'] as num).toInt()],
        name: j['n'] as String,
        group: j['g'] as String,
        url: (j['u'] as String?) ?? '',
        logo: j['l'] as String?,
        epgId: j['e'] as String?,
        number: (j['c'] as num?)?.toInt(),
        seriesId: j['si'] as String?,
        seriesName: j['sn'] as String?,
        plot: j['p'] as String?,
        rating: j['r'] as String?,
        year: j['y'] as String?,
      );
}

class EpgProgram {
  const EpgProgram({required this.start, required this.end, required this.title, this.description});

  final DateTime start;
  final DateTime end;
  final String title;
  final String? description;

  bool isAiringAt(DateTime time) => !time.isBefore(start) && time.isBefore(end);

  double progressAt(DateTime time) {
    final total = end.difference(start).inSeconds;
    if (total <= 0) return 0;
    return (time.difference(start).inSeconds / total).clamp(0.0, 1.0);
  }

  List<dynamic> toJson() => [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch, title, description];

  static EpgProgram fromJson(List<dynamic> j) => EpgProgram(
        start: DateTime.fromMillisecondsSinceEpoch((j[0] as num).toInt()),
        end: DateTime.fromMillisecondsSinceEpoch((j[1] as num).toInt()),
        title: j[2] as String,
        description: j.length > 3 ? j[3] as String? : null,
      );
}

// An episode of an Xtream series, fetched when the series is opened.
class IptvEpisode {
  const IptvEpisode({required this.title, required this.season, required this.episode, required this.url, this.image, this.plot, this.duration});
  final String title;
  final int season;
  final int episode;
  final String url;
  final String? image;
  final String? plot;
  final String? duration;
}
