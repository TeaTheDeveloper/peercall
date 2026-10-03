import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_session.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.session});

  final CallSession session;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  CallSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    session.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    super.dispose();
  }

  Future<void> _handleBack() async {
    if (session.isMinimizable) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    await session.close();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copyLink() async {
    final link = 'https://php-webrtc.unaux.com/call.php?room=${session.room}';
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Call link copied'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
  }

  /// Zoom-style grid dimensions for [count] remote tiles.
  (int cols, int rows) _gridFor(int count) {
    if (count <= 1) return (1, 1);
    if (count == 2) {
      final wide = MediaQuery.sizeOf(context).width >= 500;
      return wide ? (2, 1) : (1, 2);
    }
    if (count <= 4) return (2, 2);
    if (count <= 6) return (3, 2);
    if (count <= 9) return (3, 3);
    final cols = 4;
    final rows = (count + cols - 1) ~/ cols;
    return (cols, rows);
  }

  Widget _remoteGrid() {
    final ids = session.remotePeerIds;
    if (ids.isEmpty) {
      return _emptyState();
    }

    final (cols, rows) = _gridFor(ids.length);

    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: ids.length == 1 ? EdgeInsets.zero : const EdgeInsets.all(4),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: ids.length == 1 ? 0 : 4,
            crossAxisSpacing: ids.length == 1 ? 0 : 4,
            childAspectRatio:
                (constraints.maxWidth / cols) / (constraints.maxHeight / rows),
          ),
          itemCount: ids.length,
          itemBuilder: (context, index) {
            final peerId = ids[index];
            final renderer = session.remoteRenderers[peerId];
            if (renderer == null) {
              return const ColoredBox(color: Color(0xFF0C0C10));
            }
            return ClipRRect(
              borderRadius:
                  ids.length == 1 ? BorderRadius.zero : BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RTCVideoView(
                    renderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        peerId.length > 8 ? peerId.substring(0, 8) : peerId,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 100, 24, 170),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: const Center(
                child: Text('◉', style: TextStyle(fontSize: 28)),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              session.status,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              session.isHost
                  ? 'Share the call link. Participants will connect automatically.'
                  : 'Waiting for others to join…',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                height: 1.5,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _localPip() {
    if (session.localRenderer.srcObject == null) {
      return const SizedBox.shrink();
    }
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 70,
      right: 16,
      child: Container(
        width: 110,
        height: 160,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: RTCVideoView(
          session.localRenderer,
          mirror: true,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
      ),
    );
  }

  Widget _topBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              const Text(
                'PeerCall',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  letterSpacing: -0.3,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        session.room,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: _copyLink,
                      child: const Icon(Icons.copy_rounded, size: 16),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: session.inCall
                            ? const Color(0xFF35D07F)
                            : session.calling
                                ? const Color(0xFFFFD45C)
                                : Colors.white38,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      session.status,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.paddingOf(context).bottom + 20,
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xD60C0C10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ctrl(
                icon: session.videoEnabled
                    ? Icons.videocam_rounded
                    : Icons.videocam_off_rounded,
                onTap: session.toggleVideo,
              ),
              const SizedBox(width: 10),
              _ctrl(
                icon: session.audioEnabled
                    ? Icons.mic_rounded
                    : Icons.mic_off_rounded,
                onTap: session.toggleAudio,
              ),
              const SizedBox(width: 10),
              _ctrl(
                icon: Icons.cameraswitch_rounded,
                onTap: session.toggleCamera,
              ),
              const SizedBox(width: 10),
              _ctrl(
                icon: Icons.call_end_rounded,
                danger: true,
                onTap: () async {
                  await session.hangUp();
                  if (mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ctrl({
    required IconData icon,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    return Material(
      color: danger ? const Color(0xFFFF4D67) : Colors.white12,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  Widget _incomingOverlay() {
    if (!session.incomingVisible) return const SizedBox.shrink();
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Container(
            width: 360,
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xF0121217),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: Colors.white.withOpacity(0.08),
              ),
              child: const Icon(Icons.phone_in_talk_rounded, size: 28),
            ),
            const SizedBox(height: 18),
                const Text(
                  'Incoming call',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  'Someone is calling you.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: session.declineCall,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                        ),
                        child: const Text('Decline'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: session.acceptCall,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF08080B),
                        ),
                        child: const Text('Accept'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF08080B),
        body: Stack(
          fit: StackFit.expand,
          children: [
            _remoteGrid(),
            _localPip(),
            _topBar(),
            _controls(),
            _incomingOverlay(),
          ],
        ),
      ),
    );
  }
}
