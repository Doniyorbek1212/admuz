import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../state/providers.dart';
import '../state/telegram.dart';

/// Local path of a static map image centred on the point (sizes 16..1024 points, zoom 13..20), or null on failure.
Future<String?> loadMapThumbnail(TelegramAccount account, double latitude, double longitude, {int width = 240, int height = 140, int zoom = 15}) async {
  try {
    final file = await account.send<td.File>(td.GetMapThumbnailFile(
      location: td.Location(latitude: latitude, longitude: longitude, horizontalAccuracy: 0),
      zoom: zoom,
      width: width.clamp(16, 1024),
      height: height.clamp(16, 1024),
      scale: 2,
      chatId: 0,
    ));
    return await account.downloadFile(file.id);
  } on Exception catch (error) {
    debugPrint('map thumbnail failed: $error');
    return null;
  }
}

/// Static map from Telegram's own map service (TDLib getMapThumbnailFile, no API key), with a centre pin.
class MapThumbnail extends ConsumerStatefulWidget {
  const MapThumbnail({super.key, required this.latitude, required this.longitude, this.width = 240, this.height = 140, this.zoom = 15});

  final double latitude;
  final double longitude;
  final int width;
  final int height;
  final int zoom;

  @override
  ConsumerState<MapThumbnail> createState() => _MapThumbnailState();
}

class _MapThumbnailState extends ConsumerState<MapThumbnail> {
  late Future<String?> _path = _load();

  @override
  void didUpdateWidget(MapThumbnail old) {
    super.didUpdateWidget(old);
    if (old.latitude != widget.latitude || old.longitude != widget.longitude) _path = _load();
  }

  Future<String?> _load() =>
      loadMapThumbnail(ref.read(accountProvider), widget.latitude, widget.longitude, width: widget.width, height: widget.height, zoom: widget.zoom);

  @override
  Widget build(BuildContext context) {
    final placeholder = Theme.of(context).hintColor.withValues(alpha: 0.12);
    return SizedBox(
      width: widget.width.toDouble(),
      height: widget.height.toDouble(),
      child: FutureBuilder<String?>(
        future: _path,
        builder: (context, snapshot) {
          final path = snapshot.data;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (path == null) ColoredBox(color: placeholder) else Image.file(File(path), fit: BoxFit.cover),
              // The pin's tip sits on the centre point.
              const Align(alignment: Alignment(0, -0.2), child: Icon(Icons.location_on_rounded, color: Color(0xFFE53935), size: 38)),
            ],
          );
        },
      ),
    );
  }
}
