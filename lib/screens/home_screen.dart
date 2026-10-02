import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_session.dart';
import 'call_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _roomController = TextEditingController();
  CallSession? _session;
  bool _busy = false;

  @override
  void dispose() {
    _roomController.dispose();
    _session?.close();
    super.dispose();
  }

  String _newRoomId() {
    final now = DateTime.now();
    final millis = now.millisecondsSinceEpoch.toRadixString(36);
    final random = now.microsecondsSinceEpoch.toRadixString(36);
    return 'call_${millis.substring(millis.length > 8 ? millis.length - 8 : 0)}'
        '_${random.substring(random.length > 6 ? random.length - 6 : 0)}';
  }

  String? extractRoomId(String input) {
    input = input.trim();
    if (input.isEmpty) return null;

    final uri = Uri.tryParse(input);
    if (uri != null && uri.queryParameters['room'] != null) {
      input = uri.queryParameters['room']!;
    } else if (input.contains('room=')) {
      final q = Uri.splitQueryString(
          input.contains('?') ? input.split('?').last : input);
      if (q['room'] != null) input = q['room']!;
    }

    if (RegExp(r'^[a-zA-Z0-9_-]{3,64}$').hasMatch(input)) return input;
    return null;
  }

  bool _validRoom(String room) =>
      RegExp(r'^[a-zA-Z0-9_-]{3,64}$').hasMatch(room);

  Future<void> _openCall(String room, {required bool host}) async {
    if (_busy) return;
    setState(() => _busy = true);

    if (_session != null) {
      final old = _session!;
      old.removeListener(_sessionChanged);
      await old.close();
      _session = null;
    }

    final session = CallSession(room: room, isHost: host);
    _session = session;
    session.addListener(_sessionChanged);

    await session.initialize();

    if (!mounted) return;
    setState(() => _busy = false);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(session: session),
      ),
    );

    if (!mounted) return;
    setState(() {});
  }

  void _sessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _createRoom() async {
    final room = _newRoomId();
    _roomController.text = room;
    await _openCall(room, host: true);
  }

  Future<void> _joinRoom() async {
    final room = extractRoomId(_roomController.text.trim());
    if (!_validRoom(room!)) {
      _showMessage('Enter a valid room ID (3-64 letters, numbers, "_" or "-").');
      return;
    }
    await _openCall(room, host: false);
  }

  Future<void> _closeSession() async {
    final session = _session;
    if (session == null) return;
    await session.close();
    session.removeListener(_sessionChanged);
    if (identical(_session, session)) {
      setState(() => _session = null);
    }
  }

  void _openActiveCall() {
    final session = _session;
    if (session == null || !session.isMinimizable) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CallScreen(session: session)),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final hasCallSession = session?.isMinimizable == true;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 40, 24, 150),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.video_call_rounded, size: 58),
                      const SizedBox(height: 18),
                      const Text(
                        'PeerCall',
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Private peer-to-peer video calls.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withOpacity(.55),
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 38),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busy || hasCallSession ? null : _createRoom,
                          icon: const Icon(Icons.add_call),
                          label: Text(_busy ? 'Opening...' : 'Create call'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: Divider(color: Colors.white.withOpacity(.12))),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              'OR',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withOpacity(.4),
                              ),
                            ),
                          ),
                          Expanded(child: Divider(color: Colors.white.withOpacity(.12))),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _roomController,
                        autocorrect: false,
                        textInputAction: TextInputAction.done,
                        enabled: !hasCallSession && !_busy,
                        decoration: InputDecoration(
                          hintText: 'Enter room ID',
                          filled: true,
                          fillColor: Colors.white.withOpacity(.06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => _joinRoom(),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _busy || hasCallSession ? null : _joinRoom,
                          icon: const Icon(Icons.login_rounded),
                          label: const Text('Join call'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (hasCallSession)
              Positioned(
                left: 16,
                right: 16,
                bottom: 18,
                child: _miniCallCard(session!),
              ),
          ],
        ),
      ),
    );
  }

  String _miniCallTitle(CallSession session) {
    if (session.inCall) return 'Call in progress';
    if (session.error != null ||
        session.status.toLowerCase().contains('failed') ||
        session.status.toLowerCase().contains('error')) {
      return 'Connection error';
    }
    return session.status;
  }

  Widget _miniCallCard(CallSession session) {
    return Material(
      color: const Color(0xFF15161C),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      elevation: 12,
      child: InkWell(
        onTap: _openActiveCall,
        child: SizedBox(
          height: 94,
          child: Row(
            children: [
              SizedBox(
                width: 120,
                height: 94,
                child: session.remoteRenderer.srcObject != null
                    ? RTCVideoView(
                        session.remoteRenderer,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                    : Container(
                        color: Colors.black,
                        child: const Icon(Icons.video_call_rounded),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _miniCallTitle(session),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      session.room,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(.5),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _openActiveCall,
                tooltip: 'Open call',
                icon: const Icon(Icons.open_in_full_rounded),
              ),
              IconButton(
                onPressed: _closeSession,
                tooltip: 'End call',
                icon: const Icon(Icons.call_end_rounded, color: Colors.redAccent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
