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

  /// When true, the large view shows local and the pip shows remote.
  bool _swapped = false;

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
    // Minimize (keep session alive) when possible — this is your "PiP on back".
    if (session.isMinimizable) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    await session.close();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copyLink() async {
    // Same room id the web app uses in the URL
    final link = 'https://php-webrtc.unaux.com/call?room=${session.room}';
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

  void _onDoubleTapVideo() {
    final hasLocal = session.localRenderer.srcObject != null;
    final hasRemote = session.remoteRenderer.srcObject != null;
    if (!hasLocal || !hasRemote) return;
    setState(() => _swapped = !_swapped);
  }

  @override
  Widget build(BuildContext context) {
    final hasRemote = session.remoteRenderer.srcObject != null;
    final hasLocal = session.localRenderer.srcObject != null;

    // Which stream goes on the big view
    final RTCVideoRenderer mainRenderer =
        _swapped && hasLocal ? session.localRenderer : session.remoteRenderer;
    final RTCVideoRenderer pipRenderer =
        _swapped && hasRemote ? session.remoteRenderer : session.localRenderer;

    final showMain = _swapped ? hasLocal : hasRemote;
    final showPip = _swapped ? hasRemote : hasLocal;

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
            // ---- Main video / empty state ----
            GestureDetector(
              onDoubleTap: _onDoubleTapVideo,
              child: showMain
                  ? RTCVideoView(
                      mainRenderer,
                      mirror: _swapped, // local is mirrored
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : _emptyState(),
            ),

            // Subtle top gradient so text stays readable
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 140,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.55),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ---- PiP (local or swapped remote) ----
            if (showPip)
              Positioned(
                top: MediaQuery.of(context).padding.top + 72,
                right: 16,
                width: 112,
                height: 150,
                child: GestureDetector(
                  onDoubleTap: _onDoubleTapVideo,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.14),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.45),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: RTCVideoView(
                        pipRenderer,
                        mirror: !_swapped, // local mirrored when in pip
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),
                  ),
                ),
              ),

            // ---- UI chrome ----
            SafeArea(
              child: Column(
                children: [
                  _topBar(),
                  const Spacer(),
                  if (session.error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                      child: _errorBanner(),
                    ),
                  _controls(),
                ],
              ),
            ),

            if (session.incomingVisible) _incomingOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
      child: Row(
        children: [
          const Text(
            'PeerCall',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const Spacer(),
          // Room + copy
          Flexible(
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.only(left: 12, right: 4),
              height: 36,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      session.room,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.7),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _copyLink,
                    tooltip: 'Copy call link',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    icon: Icon(
                      Icons.copy_rounded,
                      size: 16,
                      color: Colors.white.withOpacity(0.85),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _statusPill(),
        ],
      ),
    );
  }

  Widget _statusPill() {
    final connected = session.status == 'Connected';
    final error = session.status.toLowerCase().contains('error') ||
        session.status.toLowerCase().contains('failed');
    final calling = session.status.toLowerCase().contains('calling') ||
        session.status.toLowerCase().contains('connecting');

    Color dot;
    if (error) {
      dot = const Color(0xFFFF4D67);
    } else if (connected) {
      dot = const Color(0xFF35D07F);
    } else if (calling) {
      dot = const Color(0xFFFFD45C);
    } else {
      dot = Colors.white38;
    }

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dot,
              boxShadow: connected || calling
                  ? [BoxShadow(color: dot.withOpacity(0.7), blurRadius: 8)]
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            session.status,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.68),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls() {
    final inProgress = session.inCall || session.calling;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xD60C0C10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _controlButton(
              icon: session.audioEnabled
                  ? Icons.mic_rounded
                  : Icons.mic_off_rounded,
              onPressed: session.toggleAudio,
            ),
            const SizedBox(width: 8),
            _controlButton(
              icon: session.videoEnabled
                  ? Icons.videocam_rounded
                  : Icons.videocam_off_rounded,
              onPressed: session.toggleVideo,
            ),
            const SizedBox(width: 8),
            _controlButton(
              icon: Icons.cameraswitch_rounded,
              onPressed: session.flipCamera,
            ),
            const SizedBox(width: 8),
            _controlButton(
              icon: inProgress ? Icons.call_end_rounded : Icons.call_rounded,
              destructive: inProgress,
              primary: !inProgress,
              onPressed: inProgress
                  ? session.hangUp
                  : (session.isHost && !session.roomEnded
                      ? () => session.createOffer()
                      : null),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    final title = session.roomEnded
        ? 'Call ended'
        : session.isHost
            ? 'Ready when you are'
            : session.incomingVisible
                ? 'Incoming call'
                : 'Waiting for the host';

    final subtitle = session.roomEnded
        ? 'The host ended this call.'
        : session.isHost
            ? 'Share the call link. Participants will connect when they join.'
            : 'Keep this screen open. The host will start the call automatically.';

    return Container(
      color: const Color(0xFF08080B),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(30, 100, 30, 160),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  color: Colors.white.withOpacity(0.06),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: const Icon(Icons.video_call_rounded, size: 36),
              ),
              const SizedBox(height: 22),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.7,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.55),
                  height: 1.55,
                  fontSize: 14,
                ),
              ),
              if (session.isHost && !session.roomEnded) ...[
                const SizedBox(height: 22),
                TextButton.icon(
                  onPressed: _copyLink,
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: const Text('Copy call link'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white.withOpacity(0.85),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xEB320A11),
        border: Border.all(color: const Color(0x4DFF4D67)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        session.error!,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFFFFB3BF), fontSize: 12),
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required VoidCallback? onPressed,
    bool destructive = false,
    bool primary = false,
  }) {
    Color bg;
    if (destructive) {
      bg = const Color(0xFFFF4D67);
    } else if (primary) {
      bg = Colors.white;
    } else {
      bg = Colors.white.withOpacity(0.08);
    }

    final iconColor = primary
        ? const Color(0xFF08080B)
        : (onPressed == null ? Colors.white24 : Colors.white);

    return Material(
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 50,
          height: 50,
          child: Icon(icon, color: iconColor, size: 22),
        ),
      ),
    );
  }

  Widget _incomingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.55),
      alignment: Alignment.center,
      child: Container(
        width: 360,
        margin: const EdgeInsets.all(22),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xF0121217),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 40,
            ),
          ],
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
              style: TextStyle(color: Colors.white.withOpacity(0.55)),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: session.declineCall,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.white.withOpacity(0.08),
                      side: BorderSide.none,
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
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF08080B),
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
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