import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/calls/group_call_sdp.dart';

const _offer = 'v=0\r\n'
    'o=- 1 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'a=group:BUNDLE 0 1\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111 63\r\n'
    'a=ice-ufrag:abcd\r\n'
    'a=ice-pwd:secretpwd\r\n'
    'a=fingerprint:sha-256 AA:BB:CC\r\n'
    'a=setup:actpass\r\n'
    'a=mid:0\r\n'
    'a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n'
    'a=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid\r\n'
    'a=extmap:7 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n'
    'a=sendonly\r\n'
    'a=ssrc:3000000000 cname:x\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
    'a=mid:1\r\n'
    'a=recvonly\r\n';

void main() {
  test('local offer gives ICE, DTLS, SSRC and mids', () {
    final info = parseLocalOffer(_offer);
    expect(info.ufrag, 'abcd');
    expect(info.pwd, 'secretpwd');
    expect(info.fingerprint, 'AA:BB:CC');
    expect(info.audioSsrc, 3000000000);
    expect(info.mids, ['0', '1']);
  });

  test('join payload is passive and carries the SSRC as signed 32-bit', () {
    final payload = jsonDecode(buildJoinPayload(parseLocalOffer(_offer))) as Map<String, dynamic>;
    expect(payload['ssrc'], 3000000000 - 4294967296);
    expect((payload['fingerprints'] as List).single, {'hash': 'sha-256', 'setup': 'passive', 'fingerprint': 'AA:BB:CC'});
  });

  test('extmaps are limited to the SFU ones and renumbered', () {
    final sdp = normalizeOfferExtmaps(_offer);
    expect(sdp, contains('a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level'));
    expect(sdp, contains('a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01'));
    expect(sdp, isNot(contains('sdes:mid')));
  });

  test('remote answer maps participants to mids and lists server candidates once', () {
    final transport = GroupJoinTransport.parse(jsonEncode({
      'transport': {
        'ufrag': 'srv',
        'pwd': 'srvpwd',
        'fingerprints': [
          {'hash': 'sha-256', 'fingerprint': 'DD:EE', 'setup': 'active'},
        ],
        'candidates': [
          {'foundation': '1', 'component': '1', 'protocol': 'udp', 'priority': '2130706431', 'ip': '1.2.3.4', 'port': '10000', 'type': 'host', 'generation': '0', 'id': 'x', 'network': '1'},
        ],
      },
    }));
    final answer = buildRemoteAnswer(transport: transport, mids: ['0', '1', '2'], sendMid: '0', ssrcByMid: {'1': -5}, version: 3);
    final sections = answer.split('m=audio');
    expect(sections, hasLength(4));
    expect(sections[1], contains('a=recvonly'));
    expect(sections[1], contains('a=candidate:1 1 udp 2130706431 1.2.3.4 10000 typ host generation 0'));
    expect(sections[2], contains('a=ssrc:4294967291 cname:audio4294967291'));
    expect(sections[2], contains('a=sendonly'));
    expect(sections[3], contains('a=inactive'));
    expect(sections[3], isNot(contains('a=candidate')));
    expect(answer, contains('a=setup:active'));
    expect(answer, contains('a=group:BUNDLE 0 1 2'));
  });
}
