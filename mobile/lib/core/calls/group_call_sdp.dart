import 'dart:convert';

/// SDP glue between flutter_webrtc and Telegram's group call SFU (video chats).
///
/// The SFU does not speak SDP: joining sends a JSON payload (our ICE ufrag/pwd, DTLS fingerprint, audio SSRC)
/// and gets the server transport back as JSON. These helpers turn our local offer into that payload and the
/// server transport plus the participants' audio SSRCs into a remote answer.
/// Protocol facts come from tgcalls (LGPL) GroupJoinPayloadInternal / GroupNetworkManager, no code copied.

/// The header extension ids the SFU uses for audio (tgcalls GroupInstanceCustomImpl).
const groupCallExtmaps = {
  'urn:ietf:params:rtp-hdrext:ssrc-audio-level': 1,
  'http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time': 2,
  'http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01': 3,
};

/// What the join payload needs from our local offer.
class LocalOfferInfo {
  const LocalOfferInfo({required this.ufrag, required this.pwd, required this.fingerprintHash, required this.fingerprint, required this.audioSsrc, required this.mids});

  final String ufrag;
  final String pwd;
  final String fingerprintHash;
  final String fingerprint;
  final int audioSsrc;

  /// m-line mids in offer order.
  final List<String> mids;
}

LocalOfferInfo parseLocalOffer(String sdp) {
  String? ufrag, pwd, hash, fingerprint;
  int? ssrc;
  final mids = <String>[];
  for (final line in sdp.split(RegExp(r'\r?\n'))) {
    if (line.startsWith('a=ice-ufrag:')) {
      ufrag ??= line.substring(12);
    } else if (line.startsWith('a=ice-pwd:')) {
      pwd ??= line.substring(10);
    } else if (line.startsWith('a=fingerprint:') && hash == null) {
      final parts = line.substring(14).split(' ');
      hash = parts.first;
      fingerprint = parts.last;
    } else if (line.startsWith('a=ssrc:') && ssrc == null) {
      ssrc = int.parse(line.substring(7).split(' ').first);
    } else if (line.startsWith('a=mid:')) {
      mids.add(line.substring(6));
    }
  }
  if (ufrag == null || pwd == null || hash == null || fingerprint == null || ssrc == null) {
    throw const FormatException('local offer misses ICE, DTLS or SSRC data');
  }
  return LocalOfferInfo(ufrag: ufrag, pwd: pwd, fingerprintHash: hash, fingerprint: fingerprint, audioSsrc: ssrc, mids: mids);
}

/// SSRCs are unsigned in SDP but signed 32-bit in Telegram's JSON and TDLib.
int signedSsrc(int ssrc) => ssrc.toSigned(32);
int unsignedSsrc(int ssrc) => ssrc.toUnsigned(32);

/// JSON for GroupCallJoinParameters.payload. We are the DTLS server, hence "passive".
String buildJoinPayload(LocalOfferInfo offer) => jsonEncode({
      'ufrag': offer.ufrag,
      'pwd': offer.pwd,
      'fingerprints': [
        {'hash': offer.fingerprintHash, 'setup': 'passive', 'fingerprint': offer.fingerprint},
      ],
      'ssrc': signedSsrc(offer.audioSsrc),
    });

/// Keeps only the audio header extensions the SFU knows, renumbered to its ids, so both sides agree on them.
String normalizeOfferExtmaps(String sdp) {
  final out = <String>[];
  for (final line in sdp.split(RegExp(r'\r?\n'))) {
    if (line.startsWith('a=extmap:')) {
      final uri = line.split(' ')[1];
      final id = groupCallExtmaps[uri];
      if (id == null) continue;
      out.add('a=extmap:$id $uri');
    } else if (line.isNotEmpty) {
      out.add(line);
    }
  }
  return '${out.join('\r\n')}\r\n';
}

/// Server transport from the JoinVideoChat response.
class GroupJoinTransport {
  const GroupJoinTransport({required this.ufrag, required this.pwd, required this.fingerprints, required this.candidates});

  factory GroupJoinTransport.parse(String response) {
    final json = jsonDecode(response) as Map<String, dynamic>;
    final transport = json['transport'] as Map<String, dynamic>;
    return GroupJoinTransport(
      ufrag: transport['ufrag'] as String,
      pwd: transport['pwd'] as String,
      fingerprints: [for (final f in transport['fingerprints'] as List) (hash: f['hash'] as String, fingerprint: f['fingerprint'] as String)],
      candidates: [for (final c in transport['candidates'] as List) _candidateLine((c as Map).cast<String, dynamic>())],
    );
  }

  final String ufrag;
  final String pwd;
  final List<({String hash, String fingerprint})> fingerprints;

  /// Ready "candidate:..." attribute values.
  final List<String> candidates;
}

String _candidateLine(Map<String, dynamic> c) {
  final buffer = StringBuffer('candidate:${c['foundation']} ${c['component']} ${c['protocol']} ${c['priority']} ${c['ip']} ${c['port']} typ ${c['type']}');
  if (c['rel-addr'] != null) buffer.write(' raddr ${c['rel-addr']} rport ${c['rel-port']}');
  if (c['tcptype'] != null) buffer.write(' tcptype ${c['tcptype']}');
  buffer.write(' generation ${c['generation'] ?? 0}');
  return buffer.toString();
}

/// Remote answer for our offer: [sendMid] carries our microphone to the SFU; every other mid receives
/// the participant whose audio SSRC [ssrcByMid] maps to it, or stays inactive.
String buildRemoteAnswer({
  required GroupJoinTransport transport,
  required List<String> mids,
  required String sendMid,
  required Map<String, int> ssrcByMid,
  required int version,
}) {
  final lines = <String>[
    'v=0',
    'o=- 1 $version IN IP4 0.0.0.0',
    's=-',
    't=0 0',
    'a=group:BUNDLE ${mids.join(' ')}',
  ];
  for (final (index, mid) in mids.indexed) {
    lines.addAll([
      'm=audio 9 UDP/TLS/RTP/SAVPF 111',
      'c=IN IP4 0.0.0.0',
      'a=rtcp:9 IN IP4 0.0.0.0',
      'a=ice-ufrag:${transport.ufrag}',
      'a=ice-pwd:${transport.pwd}',
      for (final f in transport.fingerprints) 'a=fingerprint:${f.hash} ${f.fingerprint}',
      'a=setup:active',
      'a=mid:$mid',
      for (final entry in groupCallExtmaps.entries) 'a=extmap:${entry.value} ${entry.key}',
      'a=rtcp-mux',
      'a=rtpmap:111 opus/48000/2',
      'a=fmtp:111 minptime=10;useinbandfec=1',
      'a=rtcp-fb:111 transport-cc',
    ]);
    final ssrc = ssrcByMid[mid];
    if (mid == sendMid) {
      lines.add('a=recvonly');
    } else if (ssrc != null) {
      final unsigned = unsignedSsrc(ssrc);
      lines.addAll(['a=sendonly', 'a=msid:audio$unsigned audio$unsigned', 'a=ssrc:$unsigned cname:audio$unsigned']);
    } else {
      lines.add('a=inactive');
    }
    if (index == 0) {
      lines.addAll([for (final candidate in transport.candidates) 'a=$candidate', 'a=end-of-candidates']);
    }
  }
  return '${lines.join('\r\n')}\r\n';
}
