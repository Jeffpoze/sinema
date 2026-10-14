import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

// Every piece of artwork in the app goes through this so loading feels the
// same everywhere: images fade in as they arrive instead of popping, and when
// the URL behind a slot changes (a carousel advancing, a season switch) the
// previous image stays up until the new one is ready and then crossfades,
// rather than flashing to an empty box in between.
class SinemaImage extends StatelessWidget {
  const SinemaImage({
    super.key,
    required this.imageUrl,
    this.httpHeaders,
    this.fit,
    this.width,
    this.height,
    this.memCacheWidth,
    this.placeholder,
    this.errorWidget,
  });

  final String imageUrl;
  final Map<String, String>? httpHeaders;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final PlaceholderWidgetBuilder? placeholder;
  final LoadingErrorWidgetBuilder? errorWidget;

  static const fadeInDuration = Duration(milliseconds: 420);
  static const fadeOutDuration = Duration(milliseconds: 260);

  @override
  Widget build(BuildContext context) => CachedNetworkImage(
        imageUrl: imageUrl,
        httpHeaders: httpHeaders,
        fit: fit,
        width: width,
        height: height,
        memCacheWidth: memCacheWidth,
        placeholder: placeholder,
        errorWidget: errorWidget,
        fadeInDuration: fadeInDuration,
        fadeInCurve: Curves.easeOutCubic,
        fadeOutDuration: fadeOutDuration,
        fadeOutCurve: Curves.easeIn,
        useOldImageOnUrlChange: true,
      );
}
