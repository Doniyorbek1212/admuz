import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// Telegram's in-chat sounds: a short cue when a message is sent and when one arrives in the open chat.
/// The sounds are synthesized here (no bundled audio files) and cached as WAVs in the temp folder.
class ChatSounds {
  ChatSounds._();

  static final ChatSounds instance = ChatSounds._();

  /// Sound ids in picker order; 'none' plays nothing.
  static const ids = ['swoosh', 'pop', 'bubble', 'ding', 'chime', 'click', 'none'];
  static const defaultSend = 'swoosh';
  static const defaultReceive = 'pop';
  static const _sampleRate = 44100;

  /// Looping call tones, not in the picker: the caller's ringback ("tuut... tuut...") and the incoming ringtone.
  static const callTones = ['ringback', 'ringtone'];

  // Its own player without audio focus, so a cue never pauses music or a voice note.
  AudioPlayer? _player;

  // Call tones take audio focus: a ringing call should pause music.
  AudioPlayer? _loopPlayer;
  String? _looping;
  final Map<String, Future<String>> _files = {};

  Future<void> play(String id) async {
    if (id == 'none' || !ids.contains(id)) return;
    try {
      final player = _player ??= AudioPlayer(handleAudioSessionActivation: false, handleInterruptions: false);
      await player.setVolume(0.7);
      await player.setFilePath(await _files.putIfAbsent(id, () => _write(id)));
      await player.play();
    } on Exception catch (error) {
      debugPrint('chat sound failed: $error');
    }
  }

  /// Repeats one of [callTones] until [stopLoop]; starting the tone already playing does nothing.
  /// shortcut: plays as media, so it ignores the phone's silent mode; a native ringtone stream comes with full-screen incoming calls.
  Future<void> loop(String id) async {
    if (!callTones.contains(id) || _looping == id) return;
    _looping = id;
    try {
      final player = _loopPlayer ??= AudioPlayer();
      final path = await _files.putIfAbsent(id, () => _write(id));
      if (_looping != id) return;
      await player.setVolume(id == 'ringback' ? 0.5 : 1);
      await player.setLoopMode(LoopMode.all);
      await player.setFilePath(path);
      if (_looping != id) return;
      // play() completes only when playback stops, so don't await it.
      unawaited(player.play());
    } on Exception catch (error) {
      debugPrint('call tone failed: $error');
    }
  }

  Future<void> stopLoop() async {
    if (_looping == null) return;
    _looping = null;
    try {
      await _loopPlayer?.stop();
    } on Exception catch (error) {
      debugPrint('call tone stop failed: $error');
    }
  }

  Future<String> _write(String id) async {
    final file = File('${(await getTemporaryDirectory()).path}/chat_sound_$id.wav');
    await file.writeAsBytes(wav(synthesize(id)));
    return file.path;
  }

  /// Mono samples in -1..1 for one of [ids].
  @visibleForTesting
  static Float64List synthesize(String id) => switch (id) {
        // Rising airy sweep: the send cue.
        'swoosh' => _tone(0.16, (t) => 380 + 1400 * t / 0.16, attack: 0.04, decay: 18, noise: 0.25),
        // Falling blip: the receive cue.
        'pop' => _tone(0.09, (t) => 950 - 3800 * t, attack: 0.003, decay: 38),
        'bubble' => _tone(0.11, (t) => 520 + 4200 * t, attack: 0.004, decay: 30),
        'ding' => _tone(0.5, (_) => 1318.5, attack: 0.002, decay: 9, overtone: 0.35),
        'chime' => _concat([_tone(0.13, (_) => 880, attack: 0.003, decay: 22), _tone(0.3, (_) => 1174.7, attack: 0.003, decay: 12)]),
        'click' => _tone(0.025, (_) => 3200, attack: 0.0005, decay: 160, noise: 0.5),
        // One 4 s cycle of the standard 425 Hz ringback: 1 s tone, 3 s silence.
        'ringback' => _concat([_beep(1, 425), Float64List(3 * _sampleRate)]),
        // One ~2.6 s cycle: two bell arpeggios, then a pause.
        'ringtone' => _concat([
            for (var i = 0; i < 2; i++) ...[
              for (final hz in [1318.5, 1046.5, 1568.0, 2093.0]) _tone(0.16, (_) => hz, attack: 0.003, decay: 9, overtone: 0.3),
              Float64List(_sampleRate ~/ 5),
            ],
            Float64List(_sampleRate),
          ]),
        _ => Float64List(0),
      };

  /// A steady sine with 10 ms fades, so a looped tone doesn't click.
  static Float64List _beep(double seconds, double frequency) {
    final count = (seconds * _sampleRate).round();
    const fade = _sampleRate ~/ 100;
    return Float64List.fromList([
      for (var i = 0; i < count; i++) 0.8 * min(1.0, min(i, count - 1 - i) / fade) * sin(2 * pi * frequency * i / _sampleRate),
    ]);
  }

  /// A sine whose frequency follows [frequency] over time, with an exponential decay envelope.
  static Float64List _tone(double seconds, double Function(double t) frequency,
      {required double attack, required double decay, double overtone = 0, double noise = 0}) {
    final count = (seconds * _sampleRate).round();
    final samples = Float64List(count);
    final random = Random(7);
    var phase = 0.0;
    for (var i = 0; i < count; i++) {
      final t = i / _sampleRate;
      phase += 2 * pi * frequency(t) / _sampleRate;
      final envelope = min(1.0, t / attack) * exp(-decay * t) * (1 - i / count);
      final tone = sin(phase) + overtone * sin(2 * phase);
      samples[i] = envelope * (tone * (1 - noise) + (random.nextDouble() * 2 - 1) * noise) / (1 + overtone);
    }
    return samples;
  }

  static Float64List _concat(List<Float64List> parts) =>
      Float64List.fromList([for (final part in parts) ...part]);

  /// 16-bit PCM mono WAV.
  @visibleForTesting
  static Uint8List wav(Float64List samples) {
    final data = ByteData(44 + samples.length * 2);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        data.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + samples.length * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, _sampleRate, Endian.little);
    data.setUint32(28, _sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
