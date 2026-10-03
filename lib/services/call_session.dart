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

  /// peerId → renderer for that remote stream
  final Map<String, RTCVideoRenderer> remoteRenderers = {};

  StreamSubscription? _signalSub;
  StreamSubscription? _remoteSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _peerLeftSub;

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
  final Set<String> _offeredPeers = {};
  bool _closed = false;

  List<String> get remotePeerIds => remoteRenderers.keys.toList();

  Future<void> initialize() async {
    if (initialized || _closed) return;
    initialized = true;

    await localRenderer.initialize();

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
    _peerLeftSub?.cancel();

    _remoteSub = webrtc.remoteStreams.listen((entry) async {
      if (_closed) return;
      final peerId = entry.key;
      final stream = entry.value;

      try {
        var renderer = remoteRenderers[peerId];
        if (renderer == null) {
          renderer = RTCVideoRenderer();
          await renderer.initialize();
          remoteRenderers[peerId] = renderer;
        }
        renderer.srcObject = stream;
        debugPrint(
          '[Call] Remote stream for $peerId '
          'video=${stream.getVideoTracks().length} '
          'audio=${stream.getAudioTracks().length}',
        );
      } catch (e) {
        debugPrint('[Call] remote srcObject failed peer=$peerId: $e');
        return;
      }

      inCall = true;
      calling = false;
      status = remoteRenderers.length > 1
          ? '${remoteRenderers.length} connected'
          : 'Connected';
      notifyListeners();
    });

    _stateSub = webrtc.states.listen((state) {
      if (_closed) return;
      final lower = state.toLowerCase();

      final isConnected =
          lower.contains('connected') || lower.contains('completed');
      final isFailed = lower.contains('failed');
      final isConnecting = lower.contains('connecting') ||
          lower.contains('checking') ||
          lower.contains('new');

      if (isFailed) {
        // One peer failed — don't tear down whole call if others remain
        if (remoteRenderers.isEmpty) {
          inCall = false;
          calling = false;
          status = 'Connection failed';
        }
      } else if (isConnected) {
        calling = false;
        inCall = true;
        status = remoteRenderers.length > 1
            ? '${remoteRenderers.length} connected'
            : 'Connected';
      } else if (isConnecting && !inCall) {
        status = 'Connecting...';
      }

      notifyListeners();
    });

    _peerLeftSub = webrtc.peerLeft.listen((peerId) async {
      await _disposeRemoteRenderer(peerId);
      _offeredPeers.remove(peerId);
      if (remoteRenderers.isEmpty) {
        inCall = false;
        status = 'Peer left';
      } else {
        status = remoteRenderers.length > 1
            ? '${remoteRenderers.length} connected'
            : 'Connected';
      }
      notifyListeners();
    });
  }

  Future<void> _disposeRemoteRenderer(String peerId) async {
    final r = remoteRenderers.remove(peerId);
    if (r == null) return;
    try {
      r.srcObject = null;
      await r.dispose();
    } catch (_) {}
  }

  Future<void> _handleSignal(SignalMessage message) async {
    if (_closed) return;
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
    if (roomEnded || message.client.isEmpty) return;
    if (message.client == signaling.clientId) return;

    final data = message.data;
    final role = data is Map ? data['role']?.toString() : null;

    // Host always offers to participants
    if (isHost) {
      if (role != null && role != 'participant') return;
      if (_offeredPeers.contains(message.client)) return;
      _offeredPeers.add(message.client);
      debugPrint('[Call] Host → offer to ${message.client}');
      await createOffer(target: message.client);
      return;
    }

    // Mesh: participant offers only if our id < theirs (avoid glare)
    if (signaling.clientId.compareTo(message.client) < 0) {
      if (_offeredPeers.contains(message.client)) return;
      _offeredPeers.add(message.client);
      debugPrint('[Call] Mesh offer ${signaling.clientId} → ${message.client}');
      await createOffer(target: message.client, mesh: true);
    }
  }

  /// [mesh] allows non-host to create offers for participant–participant links.
  Future<void> createOffer({String? target, bool mesh = false}) async {
    if (roomEnded || _closed) return;
    if (!isHost && !mesh) return;

    try {
      error = null;
      if (isHost) {
        calling = true;
        status = 'Calling...';
      } else {
        status = 'Connecting...';
      }
      notifyListeners();

      await webrtc.initializeLocalMedia();
      localRenderer.srcObject = webrtc.localStream;

      final peerId = target;
      if (peerId == null) {
        debugPrint('[Call] createOffer with no target — waiting for join');
        return;
      }

      final offer = await webrtc.createOffer(
        peerId: peerId,
        onIceCandidate: (pid, candidate) async {
          try {
            await signaling.send(
              'candidate',
              _candidateToMap(candidate),
              pid,
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
    if (message.target != null && message.target != signaling.clientId) return;
    if (message.data is! Map) return;

    // Already connected / connecting to this peer — ignore duplicate
    if (webrtc.peers.containsKey(message.client) &&
        remoteRenderers.containsKey(message.client)) {
      return;
    }

    final data = Map<String, dynamic>.from(message.data as Map);
    final sdp = data['sdp']?.toString();
    final type = data['type']?.toString();
    if (sdp == null || type == null) return;

    final offer = RTCSessionDescription(sdp, type);

    // First offer while idle → show Accept UI (host calling us)
    // Later mesh offers → auto-answer
    final isFirst = !inCall && !incomingVisible && remoteRenderers.isEmpty;

    if (isFirst && !isHost) {
      _pendingOffer = offer;
      _pendingCallerId = message.client;
      incomingVisible = true;
      status = 'Incoming call...';
      notifyListeners();
      return;
    }

    // Auto-answer mesh / subsequent offers
    await _answerOffer(message.client, offer);
  }

  Future<void> acceptCall() async {
    final offer = _pendingOffer;
    final callerId = _pendingCallerId;
    if (offer == null || callerId == null || _closed) return;

    incomingVisible = false;
    status = 'Connecting...';
    notifyListeners();

    await _answerOffer(callerId, offer);
    _pendingOffer = null;
    _pendingCallerId = null;
  }

  Future<void> _answerOffer(String peerId, RTCSessionDescription offer) async {
    try {
      await webrtc.initializeLocalMedia();
      localRenderer.srcObject = webrtc.localStream;

      final answer = await webrtc.createAnswer(
        peerId: peerId,
        offer: offer,
        onIceCandidate: (pid, candidate) async {
          try {
            await signaling.send(
              'candidate',
              _candidateToMap(candidate),
              pid,
            );
          } catch (e) {
            debugPrint('[Call] send candidate failed: $e');
          }
        },
      );

      await signaling.send('answer', _sdpToMap(answer), peerId);
      debugPrint('[Call] Answer sent to $peerId');
    } catch (e, st) {
      error = 'Could not accept the call: $e';
      debugPrint('CallSession._answerOffer error: $e\n$st');
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
      await webrtc.setAnswer(
        peerId: message.client,
        answer: RTCSessionDescription(sdp, type),
      );
      if (!inCall) status = 'Connecting...';
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

    await webrtc.addCandidate(peerId: message.client, candidate: candidate);
  }

  Future<void> _handleRemoteLeave(SignalMessage message) async {
    final data = message.data;
    final hostEnded =
        data is Map && data['hostEnded'] == true;

    if (hostEnded) {
      roomEnded = true;
    }

    await webrtc.closePeer(message.client);
    await _disposeRemoteRenderer(message.client);
    _offeredPeers.remove(message.client);

    if (remoteRenderers.isEmpty) {
      inCall = false;
      calling = false;
      status = hostEnded ? 'Host ended the call' : 'Peer left';
    } else {
      status = remoteRenderers.length > 1
          ? '${remoteRenderers.length} connected'
          : 'Connected';
    }
    notifyListeners();
  }

  Future<void> _handleDecline(SignalMessage message) async {
    await webrtc.closePeer(message.client);
    await _disposeRemoteRenderer(message.client);
    _offeredPeers.remove(message.client);
    if (remoteRenderers.isEmpty) {
      calling = false;
      status = 'Call declined';
    }
    notifyListeners();
  }

  Future<void> hangUp() async {
    if (_closed) return;
    try {
      await signaling.send('leave', {'hostEnded': isHost});
    } catch (_) {}
    await close();
  }

  Future<void> toggleCamera() async {
    await webrtc.toggleCamera();
    notifyListeners();
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

  bool get isMinimizable => inCall && !ended && !_closed;

  bool get isActive => inCall;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ended = true;

    await _signalSub?.cancel();
    await _remoteSub?.cancel();
    await _stateSub?.cancel();
    await _peerLeftSub?.cancel();

    for (final id in remoteRenderers.keys.toList()) {
      await _disposeRemoteRenderer(id);
    }

    try {
      localRenderer.srcObject = null;
      await localRenderer.dispose();
    } catch (_) {}

    await webrtc.close();
    await signaling.stop(announceLeave: true, hostEnded: isHost);

    inCall = false;
    calling = false;
    status = isHost ? 'Call ended' : 'Waiting for the host to start a call.';
    notifyListeners();
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

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse(v.toString());
  }
}
