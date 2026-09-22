# PeerCall Flutter

Flutter mobile client for PeerCall, using `flutter_webrtc` for the actual peer-to-peer media connection based on the existing [WebRTC project](https://github.com/TeaTheDeveloper/PHP-WebRTC).

## Architecture

- Flutter: UI, camera/microphone, WebRTC connection.
- PHP: signaling API only (`join`, `offer`, `answer`, `candidate`, `leave`, `decline`).
- WebRTC: carries audio/video between peers.
- STUN: helps peers discover reachable network addresses.

The PHP server does **not** carry the video stream.

## Current signaling compatibility

The client matches the existing PHP API shape:

- `POST /home?action=send&room=ROOM&client=CLIENT`
- `GET /home?action=poll&room=ROOM&client=CLIENT`

Polling is intentionally 1 second rather than 500 ms to reduce shared-host/server load. It does not control media latency after WebRTC connects.

## Run

```bash
flutter pub get
flutter run
```

For Android, grant camera and microphone permissions when prompted.

For iOS, merge the keys from `ios/Runner/Info.plist.additions` into `ios/Runner/Info.plist`.

## Room behavior

Enter the room ID used by the web PeerCall app, for example:

`call_93dfd9bbc1bc5729`

The Flutter client can therefore interoperate with the current PHP signaling backend.

## Important next production improvements

1. Replace HTTP polling with WebSocket signaling when the PHP backend supports it.
2. Add a TURN server for networks where direct WebRTC connectivity fails.
3. Add deep links/app links so an invite URL can open PeerCall directly.
4. Add call notifications for background/incoming calls.
5. Add stronger room authorization/expiry if rooms become public.
