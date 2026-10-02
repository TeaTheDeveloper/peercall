import 'dart:async';

import 'package:flutter/foundation.dart';
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
  String? _remotePeerId; // the peer we are currently connected / offering to
  final Set<String> _offeredPeers = {}; // avoid duplicate offers to same peer
  bool _closed = false;

  Future<void> initialize() async {
    if (initialized || _closed) return;
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
    } catch (e, st) {
      error = 'Could not join the call room: $e';
      debugPrint('CallSession.initialize error: $e\n$st');
      status = 'Error';
      notifyListeners();
    }
  }

  void _wireWebRtc() {
    _remoteSub?.cancel();
    _stateSub?.cancel();

    _remoteSub = webrtc.remoteStreams.listen((stream) {
      if (_closed) return;
      try {
        final videoTracks = stream.getVideoTracks().length;
        final audioTracks = stream.getAudioTracks().length;

        debugPrint(
          '[Call] Remote stream received '
          'videoTracks=$videoTracks '
          'audioTracks=$audioTracks',
        );

        remoteRenderer.srcObject = stream;
      } catch (e) {
        debugPrint('[Call] remote srcObject failed: $e');
        return;
      }
      inCall = true;
      calling = false;
      status = 'Connected';
      debugPrint('[Call] Remote stream attached → Connected');
      notifyListeners();
    });

    _stateSub = webrtc.states.listen((state) {
      if (_closed) return;
      final lower = state.toLowerCase();

      final isConnected =
          lower.contains('connected') || lower.contains('completed');
      final isFailed =
          lower.contains('failed') || lower.contains('disconnected');
      final isConnecting = lower.contains('connecting') ||
          lower.contains('checking') ||
          lower.contains('new');

      if (isFailed) {
        inCall = false;
        calling = false;
        status = 'Connection failed';
      } else if (isConnected) {
        calling = false;
        inCall = true;
        status = 'Connected';
      } else if (isConnecting && !inCall) {
        status = 'Connecting...';
      }

      notifyListeners();
    });
  }

  Future<void> _handleSignal(SignalMessage message) async {
    if (_closed) return;
    // Server already filters own messages, but be safe
    if (message.client == signaling.clientId) return;

    switch (message.event) {
      case 'join':
        await _handleJoin(message);
        break;
      case 'offer':
        await _handleOffer(message);
        break;
      case 'answer':
        await _handleAnswer(message);
        break;
      case 'candidate':
        await _handleCandidate(message);
        break;
      case 'leave':
        await _handleRemoteLeave(message);
        break;
      case 'decline':
        await _handleDecline(message);
        break;
    }
  }

  Future<void> _handleJoin(SignalMessage message) async {
    // Only host creates offers, and only for participants
    if (!isHost || roomEnded || message.client.isEmpty) return;

    final data = message.data;
    final role = data is Map ? data['role']?.toString() : null;
    if (role != 'participant') return;

    // Avoid offering the same peer repeatedly
    if (_offeredPeers.contains(message.client)) return;
    _offeredPeers.add(message.client);

    debugPrint(
        '[Call] Host saw participant join → creating offer for ${message.client}');
    await createOffer(target: message.client);
  }

  /// Host starts / restarts an outgoing call toward [target].
  Future<void> createOffer({String? target}) async {
    if (!isHost || roomEnded || _closed) return;

    try {
      error = null;
      calling = true;
      status = 'Calling...';
      notifyListeners();

      await webrtc.initializeLocalMedia();
      localRenderer.srcObject = webrtc.localStream;

      final peerId = target ?? _remotePeerId;
      if (peerId == null) {
        // No specific peer yet — just wait for a join (host is already "Calling")
        debugPrint(
            '[Call] createOffer called with no target — waiting for join');
        return;
      }

      _remotePeerId = peerId;

      final offer = await webrtc.createOffer(
        onIceCandidate: (candidate) async {
          try {
            await signaling.send(
              'candidate',
              _candidateToMap(candidate),
              peerId,
            );
          } catch (e) {
            debugPrint('[Call] send candidate failed: $e');
          }
        },
      );

      await signaling.send('offer', _sdpToMap(offer), peerId);
      debugPrint('[Call] Offer sent to $peerId');
    } catch (e, st) {
      calling = false;
      error = 'Could not start the call: $e';
      debugPrint('CallSession.createOffer error: $e\n$st');
      status = 'Error';
      notifyListeners();
    }
  }

  Future<void> _handleOffer(SignalMessage message) async {
    // Ignore offers not meant for us
    if (message.target != null && message.target != signaling.clientId) return;
    if (inCall || incomingVisible || message.data is! Map) return;

    final data = Map<String, dynamic>.from(message.data as Map);
    final sdp = data['sdp']?.toString();
    final type = data['type']?.toString();
    if (sdp == null || type == null) return;

    _pendingOffer = RTCSessionDescription(sdp, type);
    _pendingCallerId = message.client;
    _remotePeerId = message.client;
    incomingVisible = true;
    status = 'Incoming call...';
    notifyListeners();
  }

  Future<void> acceptCall() async {
    final offer = _pendingOffer;
    final callerId = _pendingCallerId;
    if (offer == null || callerId == null || _closed) return;

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
            await signaling.send(
              'candidate',
              _candidateToMap(candidate),
              callerId,
            );
          } catch (e) {
            debugPrint('[Call] send candidate failed: $e');
          }
        },
      );

      await signaling.send('answer', _sdpToMap(answer), callerId);
      _pendingOffer = null;
      _pendingCallerId = null;
      debugPrint('[Call] Answer sent to $callerId');
    } catch (e, st) {
      error = 'Could not accept the call: $e';
      debugPrint('CallSession.acceptCall error: $e\n$st');
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

  Future<void> _handleAnswer(SignalMessage message) async {
    if (message.target != null && message.target != signaling.clientId) return;
    final data = message.data;
    if (data is! Map) return;

    final answerData = Map<String, dynamic>.from(data);
    final sdp = answerData['sdp']?.toString();
    final type = answerData['type']?.toString();
    if (sdp == null || type == null) return;

    try {
      await webrtc.setAnswer(RTCSessionDescription(sdp, type));
      status = 'Connecting...';
      notifyListeners();
      debugPrint('[Call] Answer applied from ${message.client}');
    } catch (e, st) {
      error = 'Could not establish the connection: $e';
      debugPrint('CallSession._handleAnswer error: $e\n$st');
      status = 'Error';
      notifyListeners();
    }
  }

  Future<void> _handleCandidate(SignalMessage message) async {
    if (message.target != null && message.target != signaling.clientId) return;
    final data = message.data;
    if (data is! Map) return;

    final map = Map<String, dynamic>.from(data);
    final candidate = RTCIceCandidate(
      map['candidate']?.toString(),
      map['sdpMid']?.toString(),
      _asInt(map['sdpMLineIndex']),
    );

    try {
      await webrtc.addCandidate(candidate);
    } catch (e) {
      debugPrint('[Call] addCandidate error: $e');
    }
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  Map<String, dynamic> _sdpToMap(RTCSessionDescription sdp) => {
        'type': sdp.type,
        'sdp': sdp.sdp,
      };

  Map<String, dynamic> _candidateToMap(RTCIceCandidate c) => {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      };

  Future<void> _handleDecline(SignalMessage message) async {
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
      await signaling.send('leave', {'hostEnded': isHost});
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
    // keep local preview if we recreate media

    _pendingOffer = null;
    _pendingCallerId = null;
    _remotePeerId = null;
    _offeredPeers.clear();
    incomingVisible = false;
    inCall = false;
    calling = false;

    await old.close();

    webrtc = WebRtcService();
    _wireWebRtc();

    if (recreateMedia && !roomEnded && !_closed) {
      try {
        await webrtc.initializeLocalMedia();
        localRenderer.srcObject = webrtc.localStream;
      } catch (e) {
        debugPrint('[Call] recreate media failed: $e');
      }
    } else {
      localRenderer.srcObject = null;
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
    await signaling.dispose();

    await webrtc.close();

    // Dispose renderers last
    try {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
      await localRenderer.dispose();
      await remoteRenderer.dispose();
    } catch (_) {}
  }
}