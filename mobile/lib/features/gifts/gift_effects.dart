import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lottie/lottie.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api/gift_models.dart';
import '../../state/settings.dart';
import 'gift_video.dart';
import 'gift_widgets.dart';

// Premium gift shows drawn over the screen, like live-stream gifts.
// Art: Noto Animated Emoji by Google (CC BY 4.0). Sounds, CC0 from freesound.org:
// "Big Lion Roar" by _justMonke_, "Airplane passes out 1" by NoteSwiper, "NH90_flyby.aif" by ikbenraar.

const _showLength = Duration(milliseconds: 5200);

/// Plays a premium gift full screen over the current page: its rendered show (or the drawn one) for its
/// [GiftItem.effect], else its video. [sent] adds who sent it to a video; null right after sending (the sender's own preview).
Future<void> showPremiumGift(BuildContext context, GiftItem gift, {SentGift? sent}) async {
  if (gift.effect == null) return showGiftVideoOf(context, gift, sent: sent);
  if (MediaQuery.disableAnimationsOf(context)) return;
  var showUrl = gift.showUrl;
  var soundUrl = gift.soundUrl;
  // Dev test: renders served from the PC (--dart-define=GIFT_SHOW_BASE=http://127.0.0.1:8099 + adb reverse).
  const devShows = String.fromEnvironment('GIFT_SHOW_BASE');
  if (kDebugMode && devShows.isNotEmpty) (showUrl, soundUrl) = ('$devShows/${gift.effect}.webp', '$devShows/${gift.effect}.mp3');
  final soundOn = ProviderScope.containerOf(context, listen: false).read(settingsProvider).chatSounds && !await _phoneSilent();
  // Both are fetched (or taken from the disk cache) before anything shows, so picture and sound start together.
  final files = await Future.wait([
    showUrl == null ? Future<File?>.value() : _cached(showUrl),
    soundUrl == null || !soundOn ? Future<File?>.value() : _cached(soundUrl),
  ]);
  if (!context.mounted) return;
  final rendered = switch (files[0]) { final File file => await _decodeFirstFrame(context, file), null => null };
  final sound = rendered == null ? null : await _loadSound(files[1]);
  if (!context.mounted) {
    unawaited(sound?.dispose());
    return;
  }
  await Navigator.of(context, rootNavigator: true).push<void>(PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (_, _, _) => _GiftShowPage(gift: gift, rendered: rendered, sound: sound, soundOn: soundOn),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ));
}

/// True when the phone's ringer is on silent or vibrate (Android); gift shows then play without sound.
/// shortcut: iOS has no API for the mute switch, so there only the app's own sound setting applies.
Future<bool> _phoneSilent() async {
  if (!Platform.isAndroid) return false;
  try {
    return await const MethodChannel('uz.sado.app/privacy').invokeMethod<bool>('isSilent') ?? false;
  } on PlatformException catch (error) {
    debugPrint('ringer mode unknown: $error');
    return false;
  }
}

/// A show or sound kept in the temp folder by its server name (unique per upload), downloaded once.
/// Null when it cannot be fetched in time; the caller then falls back.
Future<File?> _cached(String url) async {
  final uri = Uri.parse(url);
  final dir = Directory('${(await getTemporaryDirectory()).path}/gift_media');
  final file = File('${dir.path}/${uri.pathSegments.isEmpty ? url.hashCode : uri.pathSegments.last}');
  if (await file.exists() && await file.length() > 0) return file;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final response = await (await client.getUrl(uri)).close().timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok) return null;
    await dir.create(recursive: true);
    final partial = File('${file.path}.part');
    await response.pipe(partial.openWrite()).timeout(const Duration(seconds: 30));
    return await partial.rename(file.path);
  } on IOException catch (error) {
    debugPrint('gift media download failed: $error');
    return null;
  } on TimeoutException {
    // A slow network falls back to the drawn show instead of keeping the screen waiting.
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Decodes the show's first frame, never larger than the 540×960 render; shows play once, so the page evicts it.
Future<ImageProvider?> _decodeFirstFrame(BuildContext context, File file) async {
  final image = ResizeImage(FileImage(file), width: 540, height: 960, policy: ResizeImagePolicy.fit);
  var ok = true;
  await precacheImage(image, context, onError: (error, _) {
    ok = false;
    debugPrint('gift show failed: $error');
  });
  return ok ? image : null;
}

/// A player with [file] already loaded, so play() starts at once; null without sound.
Future<AudioPlayer?> _loadSound(File? file) async {
  if (file == null) return null;
  // Mixes with music already playing in the app instead of pausing it.
  final player = AudioPlayer(handleAudioSessionActivation: false, handleInterruptions: false);
  try {
    await player.setFilePath(file.path);
    return player;
  } on PlayerException catch (error) {
    debugPrint('gift sound failed: $error');
    unawaited(player.dispose());
    return null;
  }
}

/// Effects this app knows; a newer one from the server falls back to [pop] with the gift's own picture.
enum _Show { lion, plane, helicopter, pop }

_Show _showOf(String? effect) => _Show.values.firstWhere((s) => s.name == effect, orElse: () => _Show.pop);

/// Where the gift is at one moment: centre in screen fractions, scale, turn (radians) and opacity.
typedef _Pose = ({Offset at, double scale, double angle, double opacity});

/// 0..1 progress of [t] through the stretch [from]..[to].
double _phase(double t, double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);

/// 0..1 how much of the show is on screen: fades in at the start, out at the end.
double _presence(double t) => math.min(_phase(t, 0, 0.08), 1 - _phase(t, 0.88, 1));

Offset _bezier(List<Offset> p, double u) {
  final v = 1 - u;
  return p[0] * (v * v * v) + p[1] * (3 * v * v * u) + p[2] * (3 * v * u * u) + p[3] * (u * u * u);
}

const _planePath = [Offset(-0.35, 0.86), Offset(0.2, 0.8), Offset(0.6, 0.3), Offset(1.35, 0.1)];

_Pose _pose(_Show show, double t, Size screen) => switch (show) {
      _Show.plane => _planePose(t, screen),
      _Show.helicopter => _helicopterPose(t),
      _Show.lion || _Show.pop => _popPose(t),
    };

/// Bursts out in the middle, shakes as it roars, breathes, then swells away.
_Pose _popPose(double t) {
  final grow = Curves.elasticOut.transform(_phase(t, 0.04, 0.34));
  final leave = Curves.easeInCubic.transform(_phase(t, 0.84, 1));
  final roar = _phase(t, 0.36, 0.52);
  final shake = roar > 0 && roar < 1 ? math.sin(roar * math.pi * 14) * 0.012 * (1 - roar) : 0.0;
  final breathe = 1 + 0.025 * math.sin(t * math.pi * 6);
  return (at: Offset(0.5 + shake, 0.42), scale: grow * breathe * (1 + leave * 0.5), angle: shake * 2, opacity: 1 - leave);
}

/// Climbs across the screen from the lower left, nose along its path.
_Pose _planePose(double t, Size screen) {
  final u = Curves.easeInOutSine.transform(_phase(t, 0.02, 0.92));
  final at = _bezier(_planePath, u);
  final ahead = _bezier(_planePath, math.min(1, u + 0.01));
  final heading = math.atan2((ahead.dy - at.dy) * screen.height, (ahead.dx - at.dx) * screen.width);
  // The Noto airplane points up and to the right (-45°).
  return (at: at, scale: 0.7 + 0.35 * math.sin(math.pi * u), angle: heading + math.pi / 4, opacity: 1);
}

/// Flies in from the left, hovers in the middle, leaves to the upper right.
_Pose _helicopterPose(double t) {
  final enter = Curves.easeOutCubic.transform(_phase(t, 0, 0.3));
  final leave = Curves.easeInCubic.transform(_phase(t, 0.74, 1));
  final hover = Offset(0.5, 0.36 + 0.015 * math.sin(t * math.pi * 8));
  final arrived = Offset.lerp(const Offset(-0.35, 0.22), hover, enter)!;
  // Nose down while flying, about level while hovering (the Noto helicopter faces right).
  final angle = 0.22 * (1 - enter) + 0.22 * leave + 0.04 * math.sin(t * math.pi * 5);
  return (at: Offset.lerp(arrived, const Offset(1.4, 0.1), leave)!, scale: 1.0, angle: angle, opacity: 1.0);
}

/// Just the show, no caption: the profile underneath already says whose gifts these are.
class _GiftShowPage extends StatefulWidget {
  const _GiftShowPage({required this.gift, required this.rendered, required this.sound, required this.soundOn});

  final GiftItem gift;

  /// The preloaded [GiftItem.showUrl], played instead of drawing the show; null = draw it.
  final ImageProvider? rendered;

  /// The render's own sound, loaded and waiting for the first frame; the page disposes it.
  final AudioPlayer? sound;

  /// False on a silent phone or with the app's sounds off: the drawn shows stay quiet too.
  final bool soundOn;

  @override
  State<_GiftShowPage> createState() => _GiftShowPageState();
}

class _GiftShowPageState extends State<_GiftShowPage> with SingleTickerProviderStateMixin {
  late final _Show _show = _showOf(widget.gift.effect);
  // A render lasts its duration_ms (plus a moment on its last frame); drawn shows have a fixed length.
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: switch ((widget.rendered, widget.gift.durationMs)) {
      (_?, final int ms?) => Duration(milliseconds: ms + 300),
      _ => _showLength,
    },
  );
  late final AudioPlayer _player = widget.sound ?? AudioPlayer(handleAudioSessionActivation: false, handleInterruptions: false);
  final List<_Particle> _particles = _Particle.scatter(math.Random(), 46);
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    // Started after the first frame is on screen, so the sound lines up with the picture.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_clock.forward().whenComplete(_close));
      unawaited(_playSound());
    });
  }

  Future<void> _playSound() async {
    if (widget.sound != null) return _player.play();
    if (widget.rendered != null || _show == _Show.pop || !widget.soundOn) return;
    try {
      await _player.setAsset('assets/gift_effects/${_show.name}.mp3');
      unawaited(_player.play());
    } on Exception catch (error) {
      // A show without sound is still a show.
      debugPrint('gift sound failed: $error');
    }
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _clock.dispose();
    unawaited(_player.dispose());
    // The render plays once and stays on its last frame: drop it so the next show starts from the beginning.
    unawaited(widget.rendered?.evict());
    super.dispose();
  }

  Color get _tint => switch (_show) {
        _Show.lion => const Color(0xFFFFB020),
        _Show.plane => const Color(0xFF3D8BFF),
        _Show.helicopter => const Color(0xFF26C6B0),
        _Show.pop => const Color(0xFF8B6CFF),
      };

  double _spriteSize(Size screen) => screen.shortestSide * switch (_show) {
        _Show.lion => 0.78,
        _Show.plane => 0.5,
        _Show.helicopter => 0.56,
        _Show.pop => 0.6,
      };

  Widget _sprite(double size) => switch (_show) {
        _Show.lion => Lottie.asset('assets/gift_effects/lion.json', width: size, height: size),
        // Still pictures: the Noto plane's Lottie draws its mattes as white boxes, and there is no animated helicopter.
        _Show.plane || _Show.helicopter => Image.asset('assets/gift_effects/${_show.name}.png', width: size, height: size),
        _Show.pop => GiftImage(widget.gift, size: size),
      };

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final size = _spriteSize(screen);
    if (widget.rendered case final rendered?) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: Stack(fit: StackFit.expand, children: [
          AnimatedBuilder(
            animation: _clock,
            builder: (context, _) => CustomPaint(
              painter: _ShowPainter(show: _show, t: _clock.value, tint: _tint, particles: _particles, spriteSize: size, backdropOnly: true),
            ),
          ),
          // The render carries its own motion and sparkle; it fills the width of a portrait screen.
          Image(image: rendered, fit: BoxFit.contain, gaplessPlayback: true),
        ]),
      );
    }
    final sprite = _sprite(size);
    return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: AnimatedBuilder(
          animation: _clock,
          child: sprite,
          builder: (context, sprite) {
            final t = _clock.value;
            final pose = _pose(_show, t, screen);
            return Stack(fit: StackFit.expand, children: [
              CustomPaint(painter: _ShowPainter(show: _show, t: t, tint: _tint, particles: _particles, spriteSize: size)),
              Positioned(
                left: pose.at.dx * screen.width - size / 2,
                top: pose.at.dy * screen.height - size / 2,
                width: size,
                height: size,
                child: Opacity(
                  opacity: pose.opacity.clamp(0.0, 1.0),
                  child: Transform.rotate(
                    angle: pose.angle,
                    child: Transform.scale(
                      scale: pose.scale,
                      child: Stack(children: [
                        sprite!,
                        if (_show == _Show.helicopter) _Rotor(t: t, size: size),
                      ]),
                    ),
                  ),
                ),
              ),
            ]);
          },
        ),
      );
  }
}

/// A blur flickering over the helicopter's rotor so it reads as spinning.
class _Rotor extends StatelessWidget {
  const _Rotor({required this.t, required this.size});

  final double t;
  final double size;

  @override
  Widget build(BuildContext context) {
    final spin = math.cos(t * math.pi * 90).abs();
    return Positioned(
      left: size * (0.5 - 0.46 * (0.55 + 0.45 * spin)),
      right: size * (0.5 - 0.46 * (0.55 + 0.45 * spin)),
      top: size * 0.17,
      height: size * 0.05,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size),
          color: Color.fromRGBO(220, 230, 240, 0.35 + 0.35 * spin),
        ),
      ),
    );
  }
}

/// One sparkle or confetti piece, placed by fractions of the screen.
class _Particle {
  const _Particle(this.x, this.y, this.speed, this.size, this.phase, this.hue);

  final double x, y, speed, size, phase, hue;

  static List<_Particle> scatter(math.Random r, int count) => [
        for (var i = 0; i < count; i++)
          _Particle(r.nextDouble(), r.nextDouble(), 0.4 + r.nextDouble() * 0.8, 3 + r.nextDouble() * 6, r.nextDouble() * math.pi * 2, r.nextDouble() * 360),
      ];
}

class _ShowPainter extends CustomPainter {
  _ShowPainter({required this.show, required this.t, required this.tint, required this.particles, required this.spriteSize, this.backdropOnly = false});

  final _Show show;
  final double t;
  final Color tint;
  final List<_Particle> particles;
  final double spriteSize;

  /// Only the tinted dimming, under a rendered show.
  final bool backdropOnly;

  @override
  void paint(Canvas canvas, Size size) {
    final presence = _presence(t);
    if (presence <= 0) return;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.15),
          radius: 0.95,
          colors: [tint.withValues(alpha: 0.38 * presence), Colors.black.withValues(alpha: 0.62 * presence)],
        ).createShader(rect),
    );
    if (backdropOnly) return;
    final pose = _pose(show, t, size);
    final centre = Offset(pose.at.dx * size.width, pose.at.dy * size.height);
    switch (show) {
      case _Show.lion || _Show.pop:
        _rays(canvas, centre, size, presence * math.min(1, pose.scale));
        _sparkles(canvas, size, presence, rising: true);
      case _Show.plane:
        _trail(canvas, size);
        _sparkles(canvas, size, presence, rising: false);
      case _Show.helicopter:
        _confetti(canvas, size, presence * _phase(t, 0.22, 0.32) * (1 - _phase(t, 0.82, 0.95)));
        _sparkles(canvas, size, presence, rising: false);
    }
  }

  /// Slowly turning light rays and a glow behind the gift.
  void _rays(Canvas canvas, Offset centre, Size size, double strength) {
    if (strength <= 0) return;
    canvas.drawCircle(
      centre,
      spriteSize * 0.5,
      Paint()
        ..color = tint.withValues(alpha: 0.55 * strength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 60),
    );
    const rays = 14;
    final length = size.longestSide;
    final paint = Paint()..color = tint.withValues(alpha: 0.16 * strength);
    for (var i = 0; i < rays; i++) {
      final a = t * 1.2 + i * math.pi * 2 / rays;
      final path = Path()
        ..moveTo(centre.dx, centre.dy)
        ..lineTo(centre.dx + math.cos(a - 0.07) * length, centre.dy + math.sin(a - 0.07) * length)
        ..lineTo(centre.dx + math.cos(a + 0.07) * length, centre.dy + math.sin(a + 0.07) * length)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  /// Twinkling four-point stars; [rising] ones float up.
  void _sparkles(Canvas canvas, Size size, double presence, {required bool rising}) {
    final paint = Paint()..color = Colors.white;
    for (final p in particles) {
      final y = rising ? (p.y - t * p.speed * 0.6) % 1 : p.y;
      final twinkle = 0.5 + 0.5 * math.sin(t * math.pi * 6 * p.speed + p.phase);
      final r = p.size * (0.5 + twinkle);
      final c = Offset(p.x * size.width, y * size.height);
      paint.color = Color.lerp(Colors.white, tint, 0.35)!.withValues(alpha: presence * twinkle);
      final star = Path()
        ..moveTo(c.dx, c.dy - r)
        ..quadraticBezierTo(c.dx, c.dy, c.dx + r, c.dy)
        ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + r)
        ..quadraticBezierTo(c.dx, c.dy, c.dx - r, c.dy)
        ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - r);
      canvas.drawPath(star, paint);
    }
  }

  /// White puffs left behind the plane's tail, growing and fading with age.
  void _trail(Canvas canvas, Size size) {
    final paint = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    for (var k = 28; k >= 1; k--) {
      final past = t - k * 0.012;
      if (past < 0.02) continue;
      final pose = _pose(show, past, size);
      // The tail is behind the nose: back along the heading (angle minus the sprite's -45° tilt).
      final heading = pose.angle - math.pi / 4;
      final back = spriteSize * 0.36 * pose.scale;
      final c = Offset(pose.at.dx * size.width - math.cos(heading) * back, pose.at.dy * size.height - math.sin(heading) * back);
      paint.color = Colors.white.withValues(alpha: 0.5 * (1 - k / 29) * _presence(t));
      canvas.drawCircle(c, 6 + k * 1.3, paint);
    }
  }

  /// Party confetti falling from the top while the helicopter hovers.
  void _confetti(Canvas canvas, Size size, double strength) {
    if (strength <= 0) return;
    final paint = Paint();
    final fall = _phase(t, 0.22, 1);
    for (final p in particles) {
      final y = (p.y * 0.4 - 0.3 + fall * p.speed * 1.4) % 1.2 - 0.1;
      final x = p.x + 0.03 * math.sin(t * math.pi * 4 + p.phase);
      paint.color = HSVColor.fromAHSV(strength, p.hue, 0.75, 1).toColor();
      canvas
        ..save()
        ..translate(x * size.width, y * size.height)
        ..rotate(t * 8 * p.speed + p.phase)
        ..drawRect(Rect.fromCenter(center: Offset.zero, width: p.size * 1.6, height: p.size * 0.8), paint)
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_ShowPainter old) => old.t != t || old.show != show;
}
