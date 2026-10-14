import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

// Plays a YouTube trailer inside Sinema, full screen and landscape like the
// regular player. Uses YouTube's own embedded player (the only sanctioned
// way to play YouTube video in another app). If the uploader has disabled
// embedding, it says so and offers to open the YouTube app instead.
class TrailerScreen extends StatefulWidget {
  const TrailerScreen({super.key, required this.videoId, required this.title});
  final String videoId;
  final String title;

  // Accepts youtube.com/watch?v=, youtu.be/, embed and shorts URLs.
  static String? videoIdFrom(String url) => YoutubePlayerController.convertUrlToId(url);

  @override
  State<TrailerScreen> createState() => _TrailerScreenState();
}

class _TrailerScreenState extends State<TrailerScreen> {
  late final YoutubePlayerController _controller;
  StreamSubscription<YoutubePlayerValue>? _sub;
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.videoId,
      autoPlay: true,
      params: const YoutubePlayerParams(
        showControls: true,
        showFullscreenButton: false,
        playsInline: true,
        strictRelatedVideos: true,
        showVideoAnnotations: false,
      ),
    );
    _sub = _controller.listen((value) {
      if (!mounted) return;
      if (value.error != YoutubeError.none && !_blocked) {
        setState(() => _blocked = true);
      } else if (value.playerState == PlayerState.ended) {
        Navigator.of(context).maybePop();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.close();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _openInYouTube() async {
    await launchUrl(Uri.parse('https://www.youtube.com/watch?v=${widget.videoId}'), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Center(
              child: _blocked
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('This trailer can\'t be played inside Sinema.', style: TextStyle(fontSize: 16)),
                        const SizedBox(height: 16),
                        FilledButton.icon(onPressed: _openInYouTube, icon: const Icon(Icons.open_in_new), label: const Text('Open in YouTube')),
                      ],
                    )
                  : YoutubePlayer(controller: _controller, backgroundColor: Colors.black, autoFullScreen: false, enableFullScreenOnVerticalDrag: false),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                  tooltip: 'Close trailer',
                ),
              ),
            ),
          ],
        ),
      );
}
