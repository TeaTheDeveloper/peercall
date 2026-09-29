import 'package:flutter/material.dart';
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
      Navigator.of(context).pop();
      return;
    }

    await session.close();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (_) => _handleBack(),
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (session.remoteRenderer.srcObject != null)
              RTCVideoView(
                session.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            else
              _emptyState(),

            if (session.localRenderer.srcObject != null)
              Positioned(
                top: 70,
                right: 16,
                width: 116,
                height: 154,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    color: Colors.black,
                    child: RTCVideoView(
                      session.localRenderer,
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
                    padding: const EdgeInsets.fromLTRB(18, 10, 12, 0),
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
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                    child: Row(
                      children: [
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: Text(
                              session.room,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _statusPill(),
                      ],
                    ),
                  ),
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

  Widget _statusPill() {
    final connected = session.status == 'Connected';
    final error = session.status.toLowerCase().contains('error') ||
        session.status.toLowerCase().contains('failed');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: error
                ? Colors.redAccent
                : connected
                    ? Colors.greenAccent
                    : Colors.white38,
          ),
        ),
        const SizedBox(width: 7),
        Text(
          session.status,
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withOpacity(.68),
          ),
        ),
      ],
    );
  }

  Widget _controls() {
    final connected = session.inCall || session.calling;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 26),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _controlButton(
            icon: session.audioEnabled
                ? Icons.mic_rounded
                : Icons.mic_off_rounded,
            onPressed: session.toggleAudio,
          ),
          const SizedBox(width: 10),
          _controlButton(
            icon: session.videoEnabled
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
            onPressed: session.toggleVideo,
          ),
          const SizedBox(width: 10),
          _controlButton(
            icon: Icons.cameraswitch_rounded,
            onPressed: session.flipCamera,
          ),
          const SizedBox(width: 10),
          _controlButton(
            icon: connected ? Icons.call_end_rounded : Icons.call_rounded,
            destructive: connected,
            onPressed: connected
                ? session.hangUp
                : (session.isHost && !session.roomEnded
                    ? () => session.createOffer()
                    : null),
          ),
        ],
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

    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(30, 100, 30, 150),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                color: Colors.white.withOpacity(.06),
                border: Border.all(color: Colors.white.withOpacity(.08)),
              ),
              child: const Icon(Icons.video_call_rounded, size: 36),
            ),
            const SizedBox(height: 20),
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
                color: Colors.white.withOpacity(.55),
                height: 1.5,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(.12),
        border: Border.all(color: Colors.redAccent.withOpacity(.25)),
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
  }) {
    return Material(
      color: destructive ? Colors.redAccent : Colors.white.withOpacity(.08),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 50,
          height: 50,
          child: Icon(
            icon,
            color: onPressed == null ? Colors.white24 : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _incomingOverlay() {
    return Container(
      color: Colors.black.withOpacity(.55),
      alignment: Alignment.center,
      child: Container(
        width: 360,
        margin: const EdgeInsets.all(22),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xFF121217),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withOpacity(.12)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: Colors.white.withOpacity(.08),
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
              style: TextStyle(color: Colors.white.withOpacity(.55)),
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
