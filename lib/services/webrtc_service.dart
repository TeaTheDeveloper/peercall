import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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

  RTCPeerConnection? _pc;
  MediaStream? localStream;
  MediaStream? remoteStream;

  bool _remoteDescriptionReady = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _disposed = false;

  final StreamController<MediaStream> _remoteStreamController =
      StreamController<MediaStream>.broadcast();
  final StreamController<String> _stateController =
      StreamController<String>.broadcast();

  Stream<MediaStream> get remoteStreams => _remoteStreamController.stream;
  Stream<String> get states => _stateController.stream;

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

  Future<RTCPeerConnection> _ensurePeerConnection({
    required Future<void> Function(RTCIceCandidate candidate) onIceCandidate,
  }) async {
    if (_pc != null) return _pc!;

    final pc = await createPeerConnection(_configuration);
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      onIceCandidate(candidate);
    };

    pc.onTrack = (event) {
      if (event.streams.isEmpty) return;
      remoteStream = event.streams.first;
      if (!_remoteStreamController.isClosed) {
        _remoteStreamController.add(remoteStream!);
      }
    };

    pc.onConnectionState = (state) {
      debugPrint('[WebRTC] connectionState=$state');
      if (!_stateController.isClosed) {
        _stateController.add(state.toString());
      }
    };

    pc.onIceConnectionState = (state) {
      debugPrint('[WebRTC] iceConnectionState=$state');
      if (!_stateController.isClosed) {
        _stateController.add('ICE: ${state.toString()}');
      }
    };

    if (localStream != null) {
      for (final track in localStream!.getTracks()) {
        await pc.addTrack(track, localStream!);
      }
    }

    return pc;
  }

  /// Creates offer (host side). Call only after local media is ready.
  Future<RTCSessionDescription> createOffer({
    required Future<void> Function(RTCIceCandidate candidate) onIceCandidate,
  }) async {
    final pc = await _ensurePeerConnection(onIceCandidate: onIceCandidate);

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    // Return current local description (may still gather more ICE via trickle)
    return await pc.getLocalDescription() ?? offer;
  }

  /// Creates answer (participant side).
  Future<RTCSessionDescription> createAnswer({
    required RTCSessionDescription offer,
    required Future<void> Function(RTCIceCandidate candidate) onIceCandidate,
  }) async {
    final pc = await _ensurePeerConnection(onIceCandidate: onIceCandidate);

    await pc.setRemoteDescription(offer);
    _remoteDescriptionReady = true;
    await _flushCandidates();

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    return await pc.getLocalDescription() ?? answer;
  }

  Future<void> setAnswer(RTCSessionDescription answer) async {
    final pc = _pc;
    if (pc == null) {
      debugPrint('[WebRTC] setAnswer called with no peer connection');
      return;
    }
    await pc.setRemoteDescription(answer);
    _remoteDescriptionReady = true;
    await _flushCandidates();
  }

  Future<void> addCandidate(RTCIceCandidate candidate) async {
    if (candidate.candidate == null || candidate.candidate!.isEmpty) return;

    final pc = _pc;
    if (pc == null || !_remoteDescriptionReady) {
      _pendingCandidates.add(candidate);
      return;
    }

    try {
      await pc.addCandidate(candidate);
    } catch (e) {
      debugPrint('[WebRTC] addCandidate error: $e');
    }
  }

  Future<void> _flushCandidates() async {
    final pc = _pc;
    if (pc == null) return;

    final list = List<RTCIceCandidate>.from(_pendingCandidates);
    _pendingCandidates.clear();

    for (final c in list) {
      try {
        await pc.addCandidate(c);
      } catch (e) {
        debugPrint('[WebRTC] flush candidate error: $e');
      }
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

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;

    try {
      for (final t in localStream?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      for (final t in remoteStream?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
    } catch (_) {}

    try {
      await _pc?.close();
      await _pc?.dispose();
    } catch (_) {}

    try {
      await localStream?.dispose();
      await remoteStream?.dispose();
    } catch (_) {}

    if (!_remoteStreamController.isClosed) {
      await _remoteStreamController.close();
    }
    if (!_stateController.isClosed) {
      await _stateController.close();
    }

    _pc = null;
    localStream = null;
    remoteStream = null;
    _pendingCandidates.clear();
    _remoteDescriptionReady = false;
  }
}
