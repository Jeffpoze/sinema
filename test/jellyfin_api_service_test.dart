import 'package:flutter_test/flutter_test.dart';

import 'package:sinema/services/jellyfin_api_service.dart';

void main() {
  group('JellyfinApiService.getStreamUrl', () {
    test('always requests h264/aac (only known-working request shape against Jellyfin)', () {
      final uri = Uri.parse(
        JellyfinApiService.getStreamUrl(
          'https://example.test/',
          'item-id',
          'token',
          playSessionId: 'session-id',
        ),
      );

      expect(uri.queryParameters['VideoCodec'], 'h264');
      expect(uri.queryParameters['AudioCodec'], 'aac');
      expect(uri.queryParameters['VideoBitrate'], isNull);
      expect(uri.queryParameters['PlaySessionId'], 'session-id');
    });

    test('adds a bitrate cap for bandwidth-limited playback', () {
      final uri = Uri.parse(
        JellyfinApiService.getStreamUrl(
          'https://example.test',
          'item-id',
          'token',
          maxBitrateBps: 4000000,
        ),
      );

      expect(uri.queryParameters['VideoCodec'], 'h264');
      expect(uri.queryParameters['AudioCodec'], 'aac');
      expect(uri.queryParameters['VideoBitrate'], '4000000');
    });
  });
}
