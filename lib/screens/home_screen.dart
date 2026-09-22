import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/signaling_service.dart';
import '../services/webrtc_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _roomController = TextEditingController();
  final _remoteRenderer = RTCVideoRenderer();
  final _localRenderer = RTCVideoRenderer();
  WebRtcService? _webrtc;
  SignalingService? _signaling;
  StreamSubscription? _signalSub;
  StreamSubscription? _remoteSub;
  StreamSubscription? _stateSub;

  String? _room;
  String _status = 'Ready';
  String? _error;
  bool _inCall = false;
  bool _calling = false;
  bool _incomingVisible = false;
  bool _videoEnabled = true;
  bool _audioEnabled = true;
  RTCSessionDescription? _pendingOffer;

  @override
  void initState() {
    super.initState();
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _roomController.dispose();
    _signalSub?.cancel();
    _remoteSub?.cancel();
    _stateSub?.cancel();
    _signaling?.stop();
    _webrtc?.close();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  Future<void> _joinRoom() async {
    final value = _roomController.text.trim();
    if (value.length < 3) {
      setState(() => _error = 'Enter a valid room ID.');
      return;
    }
    await _leaveRoom(silent: true);

    final signaling = SignalingService(value);
    final webrtc = WebRtcService();
    _signaling = signaling;
    _webrtc = webrtc;
    _room = value;
    _error = null;
    _status = 'Connecting...';

    _signalSub = signaling.messages.listen(_handleSignal);
    _remoteSub = webrtc.remoteStreams.listen((stream) {
      _remoteRenderer.srcObject = stream;
      if (mounted) setState(() => _status = 'Connected');
    });
    _stateSub = webrtc.states.listen((state) {
      if (!mounted) return;
      if (state.contains('connected')) {
        setState(() {
          _inCall = true;
          _calling = false;
          _status = 'Connected';
        });
      }
    });

    try {
      await signaling.start();
      await webrtc.initializeLocalMedia();
      _localRenderer.srcObject = webrtc.localStream;
      if (mounted) setState(() => _status = 'Ready');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not join: $e');
    }
  }

  Future<void> _handleSignal(SignalMessage message) async {
    if (!mounted || message.client == _signaling?.clientId) return;
    switch (message.event) {
      case 'join':
        if (!_calling && !_inCall && !_incomingVisible) {
          await _createOffer();
        }
        break;
      case 'offer':
        await _handleOffer(message.data);
        break;
      case 'answer':
        await _handleAnswer(message.data);
        break;
      case 'candidate':
        await _handleCandidate(message.data);
        break;
      case 'leave':
        await _resetCall();
        if (mounted) setState(() => _status = 'Peer left');
        break;
      case 'decline':
        await _resetCall();
        if (mounted) setState(() => _status = 'Call declined');
        break;
    }
  }

  Future<void> _createOffer() async {
    final signaling = _signaling;
    final webrtc = _webrtc;
    if (signaling == null || webrtc == null) return;
    try {
      await webrtc.initializeLocalMedia();
      _localRenderer.srcObject = webrtc.localStream;
      final offer = await webrtc.createOffer(onIceCandidate: (candidate) async {
        await signaling.send('candidate', candidate.toMap());
      });
      _calling = true;
      if (mounted) setState(() => _status = 'Calling...');
      await signaling.send('offer', offer.toMap());
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start call: $e');
    }
  }

  Future<void> _handleOffer(dynamic data) async {
    if (_inCall || _calling || _incomingVisible) return;
    if (data is! Map) return;
    final offer = RTCSessionDescription(
      data['sdp']?.toString(),
      data['type']?.toString(),
    );
    _pendingOffer = offer;
    if (mounted) {
      setState(() {
        _incomingVisible = true;
        _status = 'Incoming call...';
      });
    }
  }

  Future<void> _acceptCall() async {
    final offer = _pendingOffer;
    final signaling = _signaling;
    final webrtc = _webrtc;
    if (offer == null || signaling == null || webrtc == null) return;
    setState(() => _incomingVisible = false);
    try {
      await webrtc.initializeLocalMedia();
      _localRenderer.srcObject = webrtc.localStream;
      final answer = await webrtc.createAnswer(
        offer: offer,
        onIceCandidate: (candidate) async {
          await signaling.send('candidate', candidate.toMap());
        },
      );
      await signaling.send('answer', answer.toMap());
      _pendingOffer = null;
      if (mounted) setState(() => _status = 'Connecting...');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not accept call: $e');
    }
  }

  Future<void> _declineCall() async {
    _pendingOffer = null;
    setState(() => _incomingVisible = false);
    await _signaling?.send('decline');
    if (mounted) setState(() => _status = 'Call declined');
  }

  Future<void> _handleAnswer(dynamic data) async {
    if (data is! Map) return;
    final answer = RTCSessionDescription(
      data['sdp']?.toString(),
      data['type']?.toString(),
    );
    await _webrtc?.setAnswer(answer);
    if (mounted) setState(() => _status = 'Connecting...');
  }

  Future<void> _handleCandidate(dynamic data) async {
    if (data is! Map) return;
    final candidate = RTCIceCandidate(
      data['candidate']?.toString(),
      data['sdpMid']?.toString(),
      data['sdpMLineIndex'] is int
          ? data['sdpMLineIndex'] as int
          : int.tryParse(data['sdpMLineIndex']?.toString() ?? ''),
    );
    await _webrtc?.addCandidate(candidate);
  }

  Future<void> _hangUp() async {
    await _signaling?.send('leave');
    await _resetCall();
    if (mounted) setState(() => _status = 'Ready');
  }

  Future<void> _resetCall() async {
    _calling = false;
    _inCall = false;
    _incomingVisible = false;
    _pendingOffer = null;
    _remoteRenderer.srcObject = null;
    final old = _webrtc;
    if (old != null) {
      await old.close();
    }
    _webrtc = WebRtcService();
    _localRenderer.srcObject = null;
    if (_room != null) {
      await _webrtc!.initializeLocalMedia();
      _localRenderer.srcObject = _webrtc!.localStream;
      _wireWebRtcStreams();
    }
  }

  void _wireWebRtcStreams() {
    final webrtc = _webrtc!;
    _remoteSub?.cancel();
    _stateSub?.cancel();
    _remoteSub = webrtc.remoteStreams.listen((stream) {
      _remoteRenderer.srcObject = stream;
      if (mounted) setState(() => _status = 'Connected');
    });
    _stateSub = webrtc.states.listen((state) {
      if (!mounted) return;
      if (state.contains('connected')) {
        setState(() {
          _inCall = true;
          _calling = false;
          _status = 'Connected';
        });
      }
    });
  }

  Future<void> _toggleVideo() async {
    _videoEnabled = !_videoEnabled;
    await _webrtc?.setVideoEnabled(_videoEnabled);
    setState(() {});
  }

  Future<void> _toggleAudio() async {
    _audioEnabled = !_audioEnabled;
    await _webrtc?.setAudioEnabled(_audioEnabled);
    setState(() {});
  }

  Future<void> _copyRoom() async {
    if (_room == null) return;
    await Clipboard.setData(ClipboardData(text: _room!));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Room ID copied')),
      );
    }
  }

  Future<void> _copyInvite() async {
    if (_room == null) return;
    final invite = 'https://php-webrtc.wasmer.app/home?room=${Uri.encodeComponent(_room!)}';
    await Clipboard.setData(ClipboardData(text: invite));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invite link copied')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final inRoom = _room != null;
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_remoteRenderer.srcObject != null)
            RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          else
            _emptyState(inRoom),
          if (_localRenderer.srcObject != null)
            Positioned(
              top: 56,
              right: 16,
              width: 110,
              height: 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  color: Colors.black,
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                  child: Row(
                    children: [
                      const Text('PeerCall', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                      const Spacer(),
                      if (inRoom)
                        IconButton(
                          onPressed: _copyInvite,
                          icon: const Icon(Icons.ios_share_rounded),
                          tooltip: 'Share invite',
                        ),
                    ],
                  ),
                ),
                if (inRoom)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(30),
                          ),
                          child: Text(_room!, style: const TextStyle(fontSize: 12)),
                        ),
                        IconButton(onPressed: _copyRoom, icon: const Icon(Icons.copy, size: 18)),
                        const Spacer(),
                        Text(_status, style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                const Spacer(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                  ),
                if (!inRoom)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Column(
                      children: [
                        TextField(
                          controller: _roomController,
                          decoration: const InputDecoration(
                            hintText: 'Room ID',
                            filled: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _joinRoom,
                            icon: const Icon(Icons.login_rounded),
                            label: const Text('Join room'),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _controlButton(
                          icon: _audioEnabled ? Icons.mic : Icons.mic_off,
                          onPressed: _toggleAudio,
                        ),
                        const SizedBox(width: 12),
                        _controlButton(
                          icon: _videoEnabled ? Icons.videocam : Icons.videocam_off,
                          onPressed: _toggleVideo,
                        ),
                        const SizedBox(width: 12),
                        _controlButton(
                          icon: Icons.cameraswitch,
                          onPressed: () => _webrtc?.toggleCamera(),
                        ),
                        const SizedBox(width: 12),
                        _controlButton(
                          icon: _inCall || _calling ? Icons.call_end : Icons.call,
                          destructive: _inCall || _calling,
                          onPressed: _inCall || _calling ? _hangUp : _createOffer,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (_incomingVisible) _incomingOverlay(),
        ],
      ),
    );
  }

  Widget _emptyState(bool inRoom) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.primary.withOpacity(.15),
              ),
              child: Icon(Icons.video_call_rounded, size: 38, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 18),
            Text(
              inRoom ? 'Waiting for someone to join' : 'Private peer-to-peer calls',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              inRoom ? 'Share the room link to start a call.' : 'Create or join a room to get started.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(.65)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlButton({required IconData icon, required VoidCallback onPressed, bool destructive = false}) {
    return Material(
      color: destructive ? Colors.redAccent : Colors.white12,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(width: 56, height: 56, child: Icon(icon)),
      ),
    );
  }

  Widget _incomingOverlay() {
    return Container(
      color: Colors.black.withOpacity(.72),
      alignment: Alignment.center,
      child: Container(
        margin: const EdgeInsets.all(28),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF171921),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.phone_in_talk_rounded, size: 48),
            const SizedBox(height: 18),
            const Text('Incoming call', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('Someone is calling you.', style: TextStyle(color: Colors.white.withOpacity(.65))),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _declineCall,
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _acceptCall,
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
