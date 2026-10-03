import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// One peer connection + pending ICE state for a single remote client.
class PeerLink {
  PeerLink(this.peerId, this.pc);

  final String peerId;
  final RTCPeerConnection pc;
  bool remoteDescriptionReady = false;
  final List<RTCIceCandidate> pendingCandidates = [];
  MediaStream? remoteStream;
}

/// Multi-peer WebRTC (mesh). One [RTCPeerConnection] per remote [peerId].
class WebRtcService {
  static const Map<String, dynamic> _configuration = {
    'iceServers': [
      {
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
        ],
      },
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  MediaStream? localStream;
  bool _disposed = false;

  final Map<String, PeerLink> _peers = {};

  final StreamController<MapEntry<String, MediaStream>> _remoteStreamController =
      StreamController<MapEntry<String, MediaStream>>.broadcast();
  final StreamController<String> _stateController =
      StreamController<String>.broadcast();
  final StreamController<String> _peerLeftController =
      StreamController<String>.broadcast();

  /// Emits (peerId, remote MediaStream) when a track arrives.
  Stream<MapEntry<String, MediaStream>> get remoteStreams =>
      _remoteStreamController.stream;

  Stream<String> get states => _stateController.stream;

  /// Peer id when a connection is closed/failed and removed.
  Stream<String> get peerLeft => _peerLeftController.stream;

  Map<String, PeerLink> get peers => Map.unmodifiable(_peers);

  int get peerCount => _peers.length;

  Future<void> initializeLocalMedia() async {
    if (_disposed) return;
    if (localStream != null) return;

    localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'user',
        'frameRate': {'ideal': 30, 'max': 30},
      },
    });
  }

  Future<PeerLink> _ensurePeer({
    required String peerId,
    required Future<void> Function(String peerId, RTCIceCandidate candidate)
        onIceCandidate,
  }) async {
    final existing = _peers[peerId];
    if (existing != null) return existing;

    final pc = await createPeerConnection(_configuration);
    final link = PeerLink(peerId, pc);
    _peers[peerId] = link;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      onIceCandidate(peerId, candidate);
    };

    pc.onTrack = (event) async {
      debugPrint(
        '[WebRTC] onTrack peer=$peerId kind=${event.track.kind} '
        'streams=${event.streams.length}',
      );
      try {
        MediaStream stream;
        if (event.streams.isNotEmpty) {
          stream = event.streams.first;
        } else {
          stream = await createLocalMediaStream(
            'remote_${peerId}_${DateTime.now().millisecondsSinceEpoch}',
          );
          await stream.addTrack(event.track);
        }
        link.remoteStream = stream;
        if (!_remoteStreamController.isClosed) {
          _remoteStreamController.add(MapEntry(peerId, stream));
        }
      } catch (e, st) {
        debugPrint('[WebRTC] onTrack error peer=$peerId: $e\n$st');
      }
    };

    pc.onConnectionState = (state) {
      debugPrint('[WebRTC] peer=$peerId connectionState=$state');
      if (!_stateController.isClosed) {
        _stateController.add('PC:$peerId:${state.toString()}');
      }
      final s = state.toString().toLowerCase();
      if (s.contains('failed') || s.contains('closed')) {
        // Don't auto-remove here; CallSession may call closePeer
      }
    };

    pc.onIceConnectionState = (state) {
      debugPrint('[WebRTC] peer=$peerId iceConnectionState=$state');
      if (!_stateController.isClosed) {
        _stateController.add('ICE:$peerId:${state.toString()}');
      }
    };

    if (localStream != null) {
      for (final track in localStream!.getTracks()) {
        await pc.addTrack(track, localStream!);
      }
    }

    return link;
  }

  Future<void> _waitForIce(RTCPeerConnection pc) async {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final done = Completer<void>();
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !done.isCompleted) {
        done.complete();
      }
    };
    await Future.any([
      done.future,
      Future<void>.delayed(const Duration(seconds: 5)),
    ]);
  }

  Future<RTCSessionDescription> createOffer({
    required String peerId,
    required Future<void> Function(String peerId, RTCIceCandidate candidate)
        onIceCandidate,
  }) async {
    final link = await _ensurePeer(
      peerId: peerId,
      onIceCandidate: onIceCandidate,
    );
    final offer = await link.pc.createOffer();
    await link.pc.setLocalDescription(offer);
    await _waitForIce(link.pc);
    return await link.pc.getLocalDescription() ?? offer;
  }

  Future<RTCSessionDescription> createAnswer({
    required String peerId,
    required RTCSessionDescription offer,
    required Future<void> Function(String peerId, RTCIceCandidate candidate)
        onIceCandidate,
  }) async {
    final link = await _ensurePeer(
      peerId: peerId,
      onIceCandidate: onIceCandidate,
    );
    await link.pc.setRemoteDescription(offer);
    link.remoteDescriptionReady = true;
    await _flushCandidates(link);

    final answer = await link.pc.createAnswer();
    await link.pc.setLocalDescription(answer);
    await _waitForIce(link.pc);
    return await link.pc.getLocalDescription() ?? answer;
  }

  Future<void> setAnswer({
    required String peerId,
    required RTCSessionDescription answer,
  }) async {
    final link = _peers[peerId];
    if (link == null) {
      debugPrint('[WebRTC] setAnswer: no peer $peerId');
      return;
    }
    await link.pc.setRemoteDescription(answer);
    link.remoteDescriptionReady = true;
    await _flushCandidates(link);
  }

  Future<void> addCandidate({
    required String peerId,
    required RTCIceCandidate candidate,
  }) async {
    if (candidate.candidate == null || candidate.candidate!.isEmpty) return;

    final link = _peers[peerId];
    if (link == null || !link.remoteDescriptionReady) {
      // Queue on a placeholder if peer not ready — store on existing or skip
      if (link != null) {
        link.pendingCandidates.add(candidate);
      } else {
        debugPrint(
          '[WebRTC] candidate for unknown peer $peerId — queued after PC exists',
        );
        // Will be lost if PC never created; signaling order usually creates PC first
      }
      return;
    }

    try {
      await link.pc.addCandidate(candidate);
    } catch (e) {
      debugPrint('[WebRTC] addCandidate peer=$peerId error: $e');
    }
  }

  /// Queue candidate before PC exists by ensuring we only call after offer/answer path.
  void queueCandidate(String peerId, RTCIceCandidate candidate) {
    final link = _peers[peerId];
    if (link == null) return;
    if (!link.remoteDescriptionReady) {
      link.pendingCandidates.add(candidate);
    }
  }

  Future<void> _flushCandidates(PeerLink link) async {
    final list = List<RTCIceCandidate>.from(link.pendingCandidates);
    link.pendingCandidates.clear();
    for (final c in list) {
      try {
        await link.pc.addCandidate(c);
      } catch (e) {
        debugPrint('[WebRTC] flush candidate peer=${link.peerId}: $e');
      }
    }
  }

  Future<void> closePeer(String peerId) async {
    final link = _peers.remove(peerId);
    if (link == null) return;
    try {
      await link.pc.close();
    } catch (_) {}
    if (!_peerLeftController.isClosed) {
      _peerLeftController.add(peerId);
    }
  }

  Future<void> toggleCamera() async {
    final tracks = localStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
  }

  Future<void> setVideoEnabled(bool enabled) async {
    final tracks = localStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;
    tracks.first.enabled = enabled;
  }

  Future<void> setAudioEnabled(bool enabled) async {
    final tracks = localStream?.getAudioTracks();
    if (tracks == null || tracks.isEmpty) return;
    tracks.first.enabled = enabled;
  }

  Future<void> closeAllPeers() async {
    final ids = _peers.keys.toList();
    for (final id in ids) {
      await closePeer(id);
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;

    try {
      for (final t in localStream?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
    } catch (_) {}

    await closeAllPeers();

    try {
      await localStream?.dispose();
    } catch (_) {}
    localStream = null;

    await _remoteStreamController.close();
    await _stateController.close();
    await _peerLeftController.close();
  }
}
