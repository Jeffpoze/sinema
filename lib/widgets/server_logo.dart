import 'package:flutter/material.dart';

import '../services/jellyfin_api_service.dart';
import 'sinema_image.dart';

// The server's own logo, loaded from the icon its web app already serves, so
// Jellyfin and Emby each show their own mark. Tries the usual locations in
// turn and falls back to a plain server icon.
class ServerLogo extends StatelessWidget {
  const ServerLogo({super.key, required this.session, this.size = 44});
  final JellyfinSession session;
  final double size;

  List<String> get _candidates {
    final base = session.serverUrl.replaceFirst(RegExp(r'/+$'), '');
    // Jellyfin's web app ships its icons under /web/favicons/; Emby's sit at
    // the web root. Each list ends with the other's spots as a fallback.
    return session.serverType == MediaServerType.emby
        ? ['$base/web/touchicon144.png', '$base/web/touchicon.png', '$base/web/favicons/touchicon144.png', '$base/web/favicon.png']
        : ['$base/web/favicons/touchicon144.png', '$base/web/favicons/touchicon.png', '$base/web/touchicon.png'];
  }

  Widget _attempt(BuildContext context, int index) {
    final urls = _candidates;
    if (index >= urls.length) {
      return Icon(Icons.dns_outlined, color: Theme.of(context).colorScheme.primary, size: size * .55);
    }
    return SinemaImage(
      imageUrl: urls[index],
      fit: BoxFit.contain,
      memCacheWidth: (size * 3).round(),
      errorWidget: (context, _, _) => _attempt(context, index + 1),
    );
  }

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * .12),
        decoration: BoxDecoration(color: const Color(0xFF1B1D22), borderRadius: BorderRadius.circular(size * .26)),
        clipBehavior: Clip.antiAlias,
        child: _attempt(context, 0),
      );
}
