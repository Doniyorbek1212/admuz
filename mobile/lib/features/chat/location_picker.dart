import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/map_thumbnail.dart';

/// What [LocationPickerScreen] returns.
sealed class LocationChoice {
  const LocationChoice();
}

class PointChoice extends LocationChoice {
  const PointChoice(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

class VenueChoice extends LocationChoice {
  const VenueChoice(this.venue);

  final td.Venue venue;
}

class LiveChoice extends LocationChoice {
  const LiveChoice(this.minutes);

  final int minutes;
}

/// The point [dx], [dy] screen points away from the centre of a Web Mercator map at [zoom] (256-point tiles).
@visibleForTesting
(double, double) shiftCenter(double latitude, double longitude, int zoom, double dx, double dy) {
  final world = 256.0 * pow(2, zoom);
  final sinLat = sin(latitude * pi / 180).clamp(-0.9999, 0.9999);
  final x = (longitude + 180) / 360 * world + dx;
  final y = (0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * pi)) * world + dy;
  final n = pi - 2 * pi * y / world;
  final lon = (x / world * 360 - 180 + 540) % 360 - 180;
  return (180 / pi * atan(0.5 * (exp(n) - exp(-n))), lon);
}

/// Telegram's location tab: drag the map under a fixed pin, send that point, a nearby place, or live location.
/// The map is Telegram's own static map (no tiles or API key), re-fetched after each drag or zoom.
class LocationPickerScreen extends ConsumerStatefulWidget {
  const LocationPickerScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends ConsumerState<LocationPickerScreen> {
  static const _minZoom = 13;
  static const _maxZoom = 20;

  Position? _here;
  double? _lat;
  double? _lon;
  int _zoom = 16;
  Size _mapSize = Size.zero;
  String? _image; // Map currently on screen, centred on _lat/_lon.
  Offset _drag = Offset.zero;
  int _request = 0;
  List<td.Venue>? _venues;
  int? _venueBot;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    try {
      final here = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() => _here = here);
      await _moveTo(here.latitude, here.longitude);
    } on Exception catch (error) {
      debugPrint('location failed: $error');
    }
  }

  /// Fetches the map for the new centre and swaps it in together with the reset drag, so it never jumps.
  Future<void> _moveTo(double lat, double lon, {int? zoom}) async {
    final request = ++_request;
    final size = _mapSize == Size.zero ? const Size(400, 400) : _mapSize;
    final targetZoom = zoom ?? _zoom;
    unawaited(_loadVenues(lat, lon, request));
    final path = await loadMapThumbnail(ref.read(accountProvider), lat, lon,
        width: size.width.round(), height: size.height.round(), zoom: targetZoom);
    if (!mounted || request != _request) return;
    setState(() {
      _lat = lat;
      _lon = lon;
      _zoom = targetZoom;
      _image = path ?? _image;
      _drag = Offset.zero;
    });
  }

  /// Places around the pin from Telegram's venue bot (@foursquare), like Telegram's own picker.
  Future<void> _loadVenues(double lat, double lon, int request) async {
    final account = ref.read(accountProvider);
    try {
      final bot = _venueBot ??= switch ((await account.send<td.Chat>(const td.SearchPublicChat(username: 'foursquare'))).type) {
        td.ChatTypePrivate(:final userId) => userId,
        _ => null,
      };
      if (bot == null) return;
      final results = await account.send<td.InlineQueryResults>(td.GetInlineQueryResults(
        botUserId: bot,
        chatId: widget.chatId,
        userLocation: td.Location(latitude: lat, longitude: lon, horizontalAccuracy: 0),
        query: '',
        offset: '',
      ));
      if (!mounted || request != _request) return;
      setState(() => _venues = [for (final r in results.results) if (r is td.InlineQueryResultVenue) r.venue]);
    } on Exception catch (error) {
      debugPrint('venues failed: $error');
      if (mounted && request == _request) setState(() => _venues = const []);
    }
  }

  void _onDragEnd() {
    final lat = _lat;
    final lon = _lon;
    if (lat == null || lon == null) return;
    // Dragging the map right moves the centre left.
    final (newLat, newLon) = shiftCenter(lat, lon, _zoom, -_drag.dx, -_drag.dy);
    _moveTo(newLat, newLon);
  }

  void _zoomBy(int delta) {
    final lat = _lat;
    final lon = _lon;
    final zoom = (_zoom + delta).clamp(_minZoom, _maxZoom);
    if (lat == null || lon == null || zoom == _zoom) return;
    _moveTo(lat, lon, zoom: zoom);
  }

  /// Where the pin points now, including an unfinished drag.
  (double, double)? get _pin {
    final lat = _lat;
    final lon = _lon;
    if (lat == null || lon == null) return null;
    return _drag == Offset.zero ? (lat, lon) : shiftCenter(lat, lon, _zoom, -_drag.dx, -_drag.dy);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final here = _here;
    final pin = _pin;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('location'))),
      body: Column(
        children: [
          Expanded(flex: 5, child: _map(theme)),
          Expanded(
            flex: 6,
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                ListTile(
                  enabled: pin != null,
                  leading: CircleAvatar(backgroundColor: theme.colorScheme.primary, child: const Icon(Icons.location_on_rounded, color: Colors.white)),
                  title: Text(s.t('send_selected_location')),
                  subtitle: pin == null ? null : Text('${pin.$1.toStringAsFixed(5)}, ${pin.$2.toStringAsFixed(5)}'),
                  onTap: pin == null ? null : () => Navigator.pop(context, PointChoice(pin.$1, pin.$2)),
                ),
                if (here != null)
                  ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.my_location_rounded)),
                    title: Text(s.t('send_current_location')),
                    subtitle: Text('± ${here.accuracy.round()} m'),
                    onTap: () => Navigator.pop(context, PointChoice(here.latitude, here.longitude)),
                  ),
                for (final minutes in const [15, 60, 480])
                  ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.share_location_rounded)),
                    title: Text(s.t('share_live_location', {'time': minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h'})),
                    onTap: () => Navigator.pop(context, LiveChoice(minutes)),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(s.t('nearby_places'), style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
                ),
                if (_venues == null)
                  const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                else
                  for (final venue in _venues!)
                    ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.place_outlined)),
                      title: Text(venue.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(venue.address, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, VenueChoice(venue)),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _map(ThemeData theme) {
    final image = _image;
    return LayoutBuilder(
      builder: (context, constraints) {
        _mapSize = Size(min(constraints.maxWidth, 1024), min(constraints.maxHeight, 1024));
        return ClipRect(
          child: GestureDetector(
            onPanUpdate: (details) => setState(() => _drag += details.delta),
            onPanEnd: (_) => _onDragEnd(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: theme.hintColor.withValues(alpha: 0.12)),
                if (image != null)
                  Transform.translate(
                    offset: _drag,
                    child: Center(child: Image.file(File(image), width: _mapSize.width, height: _mapSize.height, fit: BoxFit.cover, gaplessPlayback: true)),
                  )
                else
                  const Center(child: CircularProgressIndicator()),
                // The pin's tip sits on the centre point.
                const Align(alignment: Alignment(0, -0.12), child: Icon(Icons.location_on_rounded, color: Color(0xFFE53935), size: 44)),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Column(
                    children: [
                      _mapButton(Icons.add_rounded, () => _zoomBy(1)),
                      const SizedBox(height: 8),
                      _mapButton(Icons.remove_rounded, () => _zoomBy(-1)),
                      const SizedBox(height: 8),
                      _mapButton(Icons.my_location_rounded, () {
                        final here = _here;
                        if (here != null) _moveTo(here.latitude, here.longitude);
                      }),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _mapButton(IconData icon, VoidCallback onPressed) => Material(
        color: Theme.of(context).colorScheme.surface,
        shape: const CircleBorder(),
        elevation: 2,
        child: IconButton(icon: Icon(icon), onPressed: onPressed),
      );
}
