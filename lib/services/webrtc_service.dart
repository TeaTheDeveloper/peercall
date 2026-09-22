import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'signaling_service.dart';

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

  RTCPeerConnection? _peerConnection;
  MediaStream? localStream;
  MediaStream? remoteStream;
  bool _remoteDescriptionReady = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _disposed = false;

  final StreamController<MediaStream> _remoteStreamController = StreamController.broadcast();
  final StreamController<String> _stateController = StreamController.broadcast();

  Stream<MediaStream> get remoteStreams => _remoteStreamController.stream;
  Stream<String> get states => _stateController.stream;
  RTCPeerConnection? get peerConnection => _peerConnection;

  Future<void> initializeLocalMedia() async {
    if (localStream != null) return;
    localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30, 'max': 30},
      },
    });
  }

  Future<RTCPeerConnection> createPeerConnection({
    required Future<void> Function(RTCIceCandidate candidate) onIceCandidate,
  }) async {
    if (_peerConnection != null) return _peerConnection!;

    final pc = await webrtc.createPeerConnection(_configuration);
    _peerConnection = pc;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        onIceCandidate(candidate);
      }
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteStream = event.streams.first;
        if (!_remoteStreamController.isClosed) {
          _remoteStreamController.add(remoteStream!);
        }
      }
    };

    pc.onConnectionState = (state) {
      if (!_stateController.isClosed) {
        _stateController.add(state.toString());
      }
    };

    pc.onIceConnectionState = (state) {
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

  Future<RTCSessionDescription> createOffer({
    required Future<void> Function(RTCIceCandidate candidate) onIceCandidate,
  }) async {
    final pc = await createPeerConnection(onIceCandidate: onIceCandidate);
    final offer = await pc.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await pc.setLocalDescription(offer);
    return offer;
  }

  Future<RTCSessionDescription> createAnswer({
    required RTCSessionDescription offer,
    required Future<void> Function(RTCIceCandidate candidate) onIceCandidate,
  }) async {
    final pc = await createPeerConnection(onIceCandidate: onIceCandidate);
    await pc.setRemoteDescription(offer);
    _remoteDescriptionReady = true;
    await _flushCandidates();
    final answer = await pc.createAnswer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await pc.setLocalDescription(answer);
    return answer;
  }

  Future<void> setAnswer(RTCSessionDescription answer) async {
    final pc = _peerConnection;
    if (pc == null) return;
    await pc.setRemoteDescription(answer);
    _remoteDescriptionReady = true;
    await _flushCandidates();
  }

  Future<void> addCandidate(RTCIceCandidate candidate) async {
    final pc = _peerConnection;
    if (pc == null || !_remoteDescriptionReady) {
      _pendingCandidates.add(candidate);
      return;
    }
    await pc.addCandidate(candidate);
  }

  Future<void> _flushCandidates() async {
    final pc = _peerConnection;
    if (pc == null) return;
    for (final candidate in List<RTCIceCandidate>.from(_pendingCandidates)) {
      await pc.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  Future<void> toggleCamera() async {
    final tracks = localStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;
    await tracks.first.switchCamera();
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
    for (final track in localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    for (final track in remoteStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    await localStream?.dispose();
    await remoteStream?.dispose();
    await _remoteStreamController.close();
    await _stateController.close();
    _peerConnection = null;
    localStream = null;
    remoteStream = null;
  }
}
