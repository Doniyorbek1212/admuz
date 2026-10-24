import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/calls/signaling_crypto.dart';

void main() {
  group('call signaling encryption', () {
    final key = Uint8List.fromList(List.generate(256, (i) => (i * 7 + 3) & 0xFF));
    SignalingCrypto side(bool outgoing, List<int> serviceRequests) =>
        SignalingCrypto(key: key, isOutgoing: outgoing, requestService: (delay, _) => serviceRequests.add(delay));

    test('caller message decrypts on the callee and is delivered once', () {
      final caller = side(true, []);
      final callee = side(false, []);
      final offer = utf8.encode('{"@type":"offer","sdp":"v=0"}');
      final packet = caller.prepareMessage(Uint8List.fromList(offer))!;

      expect(callee.handleIncoming(packet).map(utf8.decode), ['{"@type":"offer","sdp":"v=0"}']);
      expect(callee.handleIncoming(packet), isEmpty, reason: 'replayed packet');
    });

    test('a packet encrypted for the other direction is rejected', () {
      final caller = side(true, []);
      final otherCaller = side(true, []);
      final packet = caller.prepareMessage(Uint8List.fromList(utf8.encode('x')))!;
      expect(otherCaller.handleIncoming(packet), isEmpty);
    });

    test('callee acks the message and the caller stops resending it', () {
      final callerRequests = <int>[];
      final calleeRequests = <int>[];
      final caller = side(true, callerRequests);
      final callee = side(false, calleeRequests);
      callee.handleIncoming(caller.prepareMessage(Uint8List.fromList(utf8.encode('a')))!);
      expect(calleeRequests, contains(0), reason: 'new message needing ack asks for an immediate service packet');

      final ack = callee.prepareService(0)!;
      expect(caller.handleIncoming(ack), isEmpty);
      expect(caller.prepareService(SignalingCrypto.causeResend), isNull, reason: 'nothing left to resend');
    });

    test('unacked message is resent inside the next message packet in order', () {
      final caller = side(true, []);
      final callee = side(false, []);
      final first = caller.prepareMessage(Uint8List.fromList(utf8.encode('first')))!;
      final second = caller.prepareMessage(Uint8List.fromList(utf8.encode('second')))!;
      // The first packet was lost; the second one carries both messages.
      expect(callee.handleIncoming(second).map(utf8.decode), ['first', 'second']);
      expect(callee.handleIncoming(first), isEmpty, reason: 'late copy of an already delivered message');
    });
  });
}
