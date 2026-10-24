import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// Encrypted signaling channel of a Telegram call, wire-compatible with tgcalls'
/// EncryptedConnection (type Signaling, raw messages), the format peers expect for
/// library version "10.0.0".
///
/// Packet = msg_key(16) + AES-256-CTR(seq(4) + messages...). Messages that need an
/// ack are resent until the peer acks them; acks ride along in later packets.
class SignalingCrypto {
  SignalingCrypto({required Uint8List key, required this.isOutgoing, required this.requestService})
      : assert(key.length == 256),
        _key = key;

  final Uint8List _key;
  final bool isOutgoing;

  /// Asks the owner to call [prepareService] after [delayMs] (0 = now).
  final void Function(int delayMs, int cause) requestService;

  static const _singleMessageBit = 1 << 31;
  static const _requiresAckBit = 1 << 30;
  static const _ackId = 0xFF;
  static const _emptyId = 0xFE;
  static const _customId = 0x7F;
  static const _maxPacket = 16 * 1024;
  static const _keepIncoming = 64;
  static const causeAcks = 1;
  static const causeResend = 2;
  static const _minResendMs = 3000;
  static const _maxResendMs = 5000;
  static const _maxAckDelayMs = 5000;

  int _counter = 0;
  final List<int> _largestIncoming = [];
  final List<int> _acksToSend = [];
  final List<int> _acksSent = [];
  final List<({Uint8List data, int lastSent})> _notAcked = [];
  bool _resendTimerActive = false;
  bool _ackTimerActive = false;

  static int _counterOf(int seq) => seq & ~_singleMessageBit & ~_requiresAckBit;

  /// Encrypts one signaling message (always sent with ack, as tgcalls does).
  Uint8List? prepareMessage(Uint8List message) {
    final seq = (++_counter) | _requiresAckBit;
    final serialized = BytesBuilder()
      ..add(_u32(seq))
      ..addByte(_customId)
      ..add(_u32(message.length))
      ..add(message);
    final bytes = serialized.toBytes();
    if (16 + bytes.length > _maxPacket) return null;
    final enqueued = _notAcked.isNotEmpty;
    final packet = BytesBuilder()..add(bytes);
    if (!enqueued) _appendAdditional(packet);
    _notAcked.add((data: bytes, lastSent: _now()));
    if (!enqueued) return _encrypt(packet.toBytes());
    // Earlier messages are still unacked: send them all in order, starting with the oldest.
    for (var i = 0; i < _notAcked.length; i++) {
      _notAcked[i] = (data: _notAcked[i].data, lastSent: 0);
    }
    return prepareService(0);
  }

  /// A packet carrying only pending acks and resends; null when there is nothing to send.
  Uint8List? prepareService(int cause) {
    if (cause == causeAcks) _ackTimerActive = false;
    if (cause == causeResend) _resendTimerActive = false;
    if (_notAcked.isEmpty && _acksToSend.isEmpty) return null;
    final packet = BytesBuilder()
      ..add(_u32(++_counter))
      ..addByte(_emptyId);
    _appendAdditional(packet);
    return _encrypt(packet.toBytes());
  }

  /// Decrypts a packet from the peer and returns the new messages in it.
  List<Uint8List> handleIncoming(Uint8List packet) {
    if (packet.length < 21 || packet.length > 128 * 1024) return const [];
    final x = (isOutgoing ? 8 : 0) + 128;
    final msgKey = packet.sublist(0, 16);
    final plain = _aesCtr(packet.sublist(16), msgKey, x);
    final check = sha256.convert([..._key.sublist(88 + x, 88 + x + 32), ...plain]).bytes;
    var different = 0;
    for (var i = 0; i < 16; i++) {
      different |= check[8 + i] ^ msgKey[i];
    }
    if (different != 0) return const [];
    final reader = ByteData.sublistView(plain);
    var seq = reader.getUint32(0);
    if (!_registerIncoming(_counterOf(seq))) return const [];
    final packetCounter = _counterOf(seq);
    final result = <Uint8List>[];
    var offset = 4;
    var additional = false;
    var firstRequiringAck = true;
    var newRequiringAck = false;
    while (true) {
      final type = plain[offset];
      final single = seq & _singleMessageBit != 0;
      if (single && additional) return result;
      final counter = _counterOf(seq);
      if (type == _emptyId) {
        if (additional) return result;
        offset += 1;
      } else if (type == _ackId) {
        if (!additional) return result;
        _notAcked.removeWhere((m) => ByteData.sublistView(m.data).getUint32(0) == seq);
        offset += 1;
      } else if (type == _customId) {
        if (offset + 5 > plain.length) return result;
        final length = reader.getUint32(offset + 1);
        if (length > 1024 * 1024 || offset + 5 + length > plain.length) return result;
        final message = plain.sublist(offset + 5, offset + 5 + length);
        offset += 5 + length;
        final requiresAck = seq & _requiresAckBit != 0;
        final skip = requiresAck
            ? !_registerSentAck(counter, firstRequiringAck)
            : additional && (counter > packetCounter || !_registerIncoming(counter));
        if (requiresAck) {
          firstRequiringAck = false;
          if (!skip) newRequiringAck = true;
          if (!_acksToSend.contains(seq)) _acksToSend.add(seq);
        }
        if (!skip) result.add(message);
      } else {
        return result;
      }
      if (offset >= plain.length) break;
      if (single || plain.length - offset < 5) return result;
      seq = reader.getUint32(offset);
      offset += 4;
      additional = true;
    }
    if (_acksToSend.isNotEmpty) {
      if (newRequiringAck) {
        requestService(0, 0);
      } else if (!_ackTimerActive) {
        _ackTimerActive = true;
        requestService(_maxAckDelayMs, causeAcks);
      }
    }
    return result;
  }

  void _appendAdditional(BytesBuilder packet) {
    var taken = 0;
    for (final seq in _acksToSend) {
      if (16 + packet.length + 5 > _maxPacket) break;
      packet
        ..add(_u32(seq))
        ..addByte(_ackId);
      taken++;
    }
    _acksToSend.removeRange(0, taken);
    if (_notAcked.isEmpty) return;
    final now = _now();
    for (var i = 0; i < _notAcked.length; i++) {
      final item = _notAcked[i];
      final when = item.lastSent == 0 ? 0 : item.lastSent + _minResendMs;
      if (when > now || 16 + packet.length + item.data.length > _maxPacket) break;
      packet.add(item.data);
      _notAcked[i] = (data: item.data, lastSent: now);
    }
    if (!_resendTimerActive) {
      _resendTimerActive = true;
      requestService(_maxResendMs, causeResend);
    }
  }

  Uint8List _encrypt(Uint8List plain) {
    final x = (isOutgoing ? 0 : 8) + 128;
    final large = sha256.convert([..._key.sublist(88 + x, 88 + x + 32), ...plain]).bytes;
    final msgKey = Uint8List.fromList(large.sublist(8, 24));
    return Uint8List.fromList([...msgKey, ..._aesCtr(plain, msgKey, x)]);
  }

  /// tgcalls PrepareAesKeyIv + AES-256-CTR (the whole 16-byte IV is the big-endian counter).
  Uint8List _aesCtr(Uint8List data, Uint8List msgKey, int x) {
    final a = sha256.convert([...msgKey, ..._key.sublist(x, x + 36)]).bytes;
    final b = sha256.convert([..._key.sublist(40 + x, 40 + x + 36), ...msgKey]).bytes;
    final aesKey = Uint8List.fromList([...a.sublist(0, 8), ...b.sublist(8, 24), ...a.sublist(24, 32)]);
    final iv = Uint8List.fromList([...b.sublist(0, 4), ...a.sublist(8, 16), ...b.sublist(24, 28)]);
    final cipher = SICStreamCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(aesKey), iv));
    return cipher.process(data);
  }

  bool _registerIncoming(int counter) {
    final list = _largestIncoming;
    final largest = list.isEmpty ? 0 : list.last;
    if (list.contains(counter) || counter + _keepIncoming <= largest) return false;
    list
      ..removeWhere((c) => c + _keepIncoming <= counter)
      ..add(counter)
      ..sort();
    return true;
  }

  bool _registerSentAck(int counter, bool firstInPacket) {
    final list = _acksSent;
    final already = list.contains(counter);
    if (firstInPacket) {
      list.removeWhere((c) => c < counter);
      if (!already) list.insert(0, counter);
    } else if (!already) {
      list
        ..add(counter)
        ..sort();
    }
    return !already;
  }

  static Uint8List _u32(int value) => Uint8List(4)..buffer.asByteData().setUint32(0, value);
  static int _now() => DateTime.now().millisecondsSinceEpoch;
}
