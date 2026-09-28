import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'signaling_service.dart';
import 'webrtc_service.dart';

class CallSession extends ChangeNotifier {
  CallSession({required this.room, required this.isHost}) {
    signaling = SignalingService(room);
    webrtc = WebRtcService();
  }

  final String room;
  final bool isHost;

  late final SignalingService signaling;
  late WebRtcService webrtc;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  StreamSubscription? _signalSub;
  StreamSubscription? _remoteSub;
  StreamSubscription? _stateSub;

  String status = 'Ready';
  String? error;
  bool calling = false;
  bool inCall = false;
  bool incomingVisible = false;
  bool videoEnabled = true;
  bool audioEnabled = true;
  bool roomEnded = false;
  bool initialized = false;
  bool ended = false;

  RTCSessionDescription? _pendingOffer;
  String? _pendingCallerId;
  bool _closed = false;

  Future<void> initialize() async {
    if (initialized) return;
    initialized = true;

    await localRenderer.initialize();
    await remoteRenderer.initialize();

    _wireWebRtc();
    _signalSub = signaling.messages.listen(_handleSignal);

    try {
      if (isHost) {
        await webrtc.initializeLocalMedia();
        localRenderer.srcObject = webrtc.localStream;
        await signaling.start(role: 'host');
        calling = true;
        status = 'Calling...';
      } else {
        await signaling.start(role: 'participant');
        status = 'Waiting for the host to start a call.';
      }
      notifyListeners();
    } catch (e) {
      error = 'Could not join the call room';
      debugPrint('CallSession.initialize error: $e');
      status = 'Error';
      notifyListeners();
    }
  }

  void _wireWebRtc() {
    _remoteSub?.cancel();
    _stateSub?.cancel();

    _remoteSub = webrtc.remoteStreams.listen((stream) {
      remoteRenderer.srcObject = stream;
      inCall = true;
      calling = false;
      status = 'Connected';
      notifyListeners();
    });

    _stateSub = webrtc.states.listen((state) {
      final lower = state.toLowerCase();
      if (lower.contains('connected')) {
        inCall = true;
        calling = false;
        status = 'Connected';
      } else if (lower.contains('failed')) {
        inCall = false;
        calling = false;
        status = 'Connection failed';
      } else if (lower.contains('connecting') || lower.contains('checking')) {
        status = 'Connecting...';
      }
      notifyListeners();
    });
  }

  Future<void> _handleSignal(SignalMessage message) async {
    if (_closed || message.client == signaling.clientId) return;

    switch (message.event) {
      case 'join':
        await _handleJoin(message);
        break;
      case 'offer':
        await _handleOffer(message);
        break;
      case 'answer':
        await _handleAnswer(message.data);
        break;
      case 'candidate':
        await _handleCandidate(message.data);
        break;
      case 'leave':
        await _handleRemoteLeave(message);
        break;
      case 'decline':
        await _handleDecline();
        break;
    }
  }

  Future<void> _handleJoin(SignalMessage message) async {
    if (!isHost || roomEnded || message.client.isEmpty) return;

    final data = message.data;
    final role = data is Map ? data['role']?.toString() : null;
    if (role != 'participant') return;

    await createOffer(target: message.client);
  }

  Future<void> createOffer({String? target}) async {
    if (!isHost || roomEnded) return;

    try {
      error = null;
      calling = true;
      status = 'Calling...';
      notifyListeners();

      await webrtc.initializeLocalMedia();
      localRenderer.srcObject = webrtc.localStream;

      final offer = await webrtc.createOffer(
        onIceCandidate: (candidate) async {
          try {
            await signaling.send('candidate', candidate.toMap(), target);
          } catch (_) {}
        },
      );

      await signaling.send('offer', offer.toMap(), target);
    } catch (e) {
      calling = false;
      error = 'Could not start the call';
      debugPrint('CallSession.createOffer error: $e');
      status = 'Error';
      notifyListeners();
    }
  }

  Future<void> _handleOffer(SignalMessage message) async {
    if (message.target != null && message.target != signaling.clientId) return;
    if (inCall || calling || incomingVisible || message.data is! Map) return;

    final data = Map<String, dynamic>.from(message.data as Map);
    final sdp = data['sdp']?.toString();
    final type = data['type']?.toString();
    if (sdp == null || type == null) return;

    _pendingOffer = RTCSessionDescription(sdp, type);
    _pendingCallerId = message.client;
    incomingVisible = true;
    status = 'Incoming call...';
    notifyListeners();
  }

  Future<void> acceptCall() async {
    final offer = _pendingOffer;
    final callerId = _pendingCallerId;
    if (offer == null || callerId == null) return;

    incomingVisible = false;
    status = 'Connecting...';
    notifyListeners();

    try {
      await webrtc.initializeLocalMedia();
      localRenderer.srcObject = webrtc.localStream;

      final answer = await webrtc.createAnswer(
        offer: offer,
        onIceCandidate: (candidate) async {
          try {
            await signaling.send('candidate', candidate.toMap(), callerId);
          } catch (_) {}
        },
      );

      await signaling.send('answer', answer.toMap(), callerId);
      _pendingOffer = null;
      _pendingCallerId = null;
    } catch (e) {
      error = 'Could not accept the call';
      debugPrint('CallSession.acceptCall error: $e');
      status = 'Error';
      notifyListeners();
    }
  }

  Future<void> declineCall() async {
    final callerId = _pendingCallerId;
    _pendingOffer = null;
    _pendingCallerId = null;
    incomingVisible = false;
    status = 'Call declined';
    notifyListeners();

    if (callerId != null) {
      try {
        await signaling.send('decline', null, callerId);
      } catch (_) {}
    }
  }

  Future<void> _handleAnswer(dynamic data) async {
    if (data is! Map) return;
    final answerData = Map<String, dynamic>.from(data);
    final sdp = answerData['sdp']?.toString();
    final type = answerData['type']?.toString();
    if (sdp == null || type == null) return;

    try {
      await webrtc.setAnswer(RTCSessionDescription(sdp, type));
      status = 'Connecting...';
      notifyListeners();
    } catch (e) {
      error = 'Could not establish the connection';
      debugPrint('CallSession._handleAnswer error: $e');
      status = 'Error';
      notifyListeners();
    }
  }

  Future<void> _handleCandidate(dynamic data) async {
    if (data is! Map) return;
    final candidateData = Map<String, dynamic>.from(data);
    final candidate = RTCIceCandidate(
      candidateData['candidate']?.toString(),
      candidateData['sdpMid']?.toString(),
      _asInt(candidateData['sdpMLineIndex']),
    );

    try {
      await webrtc.addCandidate(candidate);
    } catch (_) {}
  }

  int? _asInt(dynamic value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '');

  Future<void> _handleDecline() async {
    await _resetConnection(recreateMedia: true);
    calling = false;
    status = 'Call declined';
    notifyListeners();
  }

  Future<void> _handleRemoteLeave(SignalMessage message) async {
    final data = message.data;
    final hostEnded = data is Map && data['hostEnded'] == true;

    await _resetConnection(recreateMedia: isHost && !hostEnded);

    if (hostEnded && !isHost) {
      roomEnded = true;
      status = 'Call ended';
      error = null;
    } else {
      status = 'Peer left';
    }
    notifyListeners();
  }

  Future<void> hangUp() async {
    try {
      await signaling.send('leave', <String, dynamic>{'hostEnded': isHost});
    } catch (_) {}

    await _resetConnection(recreateMedia: isHost);
    calling = false;
    inCall = false;
    roomEnded = isHost;
    status = isHost ? 'Call ended' : 'Waiting for the host to start a call.';
    notifyListeners();
  }

  Future<void> _resetConnection({required bool recreateMedia}) async {
    final old = webrtc;
    remoteRenderer.srcObject = null;
    localRenderer.srcObject = null;
    _pendingOffer = null;
    _pendingCallerId = null;
    incomingVisible = false;
    inCall = false;
    calling = false;

    await old.close();

    webrtc = WebRtcService();
    _wireWebRtc();

    if (recreateMedia && !roomEnded) {
      try {
        await webrtc.initializeLocalMedia();
        localRenderer.srcObject = webrtc.localStream;
      } catch (_) {}
    }
  }

  Future<void> toggleVideo() async {
    videoEnabled = !videoEnabled;
    await webrtc.setVideoEnabled(videoEnabled);
    notifyListeners();
  }

  Future<void> toggleAudio() async {
    audioEnabled = !audioEnabled;
    await webrtc.setAudioEnabled(audioEnabled);
    notifyListeners();
  }

  Future<void> flipCamera() => webrtc.toggleCamera();

  /// True while this session is still alive and can be reopened from Home.
  /// This intentionally includes connecting, waiting, and recoverable error states.
  bool get isMinimizable => initialized && !roomEnded && !_closed;

  bool get isActive => inCall;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    await _signalSub?.cancel();
    await _remoteSub?.cancel();
    await _stateSub?.cancel();

    try {
      await signaling.stop(announceLeave: true, hostEnded: isHost);
    } catch (_) {}

    await webrtc.close();
    await localRenderer.dispose();
    await remoteRenderer.dispose();
  }
}
