import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

class SignalMessage {
  final String id;
  final String event;
  final dynamic data;
  final String client;
  final String? target;
  final int? time;

  SignalMessage({
    required this.id,
    required this.event,
    required this.data,
    required this.client,
    this.target,
    this.time,
  });

  factory SignalMessage.fromJson(Map<String, dynamic> json) {
    return SignalMessage(
      id: json['id']?.toString() ?? '',
      event: json['event']?.toString() ?? '',
      data: json['data'],
      client: json['client']?.toString() ?? '',
      target: json['target']?.toString(),
      time: int.tryParse(json['time']?.toString() ?? ''),
    );
  }
}

class SignalingService {
  static const String baseUrl = 'https://php-webrtc.unaux.com/call';
  static const Duration pollInterval = Duration(seconds: 3);

  final String room;
  final String clientId = _makeClientId();

  Timer? _timer;
  bool _running = false;
  final Set<String> _processedIds = <String>{};

  /// Cookie solved from the free-host AES challenge
  String? _testCookie;

  final StreamController<SignalMessage> _messages =
      StreamController<SignalMessage>.broadcast();

  Stream<SignalMessage> get messages => _messages.stream;

  SignalingService(this.room);

  static String _makeClientId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return 'mobile_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  Map<String, String> get _headers {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Accept': 'application/json, text/plain, */*',
    };
    if (_testCookie != null) {
      h['Cookie'] = '__test=$_testCookie';
    }
    return h;
  }

  Future<void> start({required String role}) async {
    if (_running) return;
    _running = true;

    // Solve challenge once before any real request
    await _ensureChallengeSolved();

    await send('join', {
      'joinedAt': DateTime.now().millisecondsSinceEpoch,
      'role': role,
    });

    _timer = Timer.periodic(pollInterval, (_) => poll());
    await poll();
  }

  Future<void> stop({
    required bool announceLeave,
    required bool hostEnded,
  }) async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;

    if (announceLeave) {
      try {
        await send('leave', {'hostEnded': hostEnded});
      } catch (e) {
        debugPrint('[Signaling] leave failed: $e');
      }
    }
  }

  Future<void> dispose() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    if (!_messages.isClosed) await _messages.close();
  }


  // AES challenge solver

  Future<void> _ensureChallengeSolved() async {
    if (_testCookie != null) return;

    final uri = Uri.parse(baseUrl).replace(queryParameters: {
      'action': 'poll',
      'room': room,
      'client': clientId,
    });

    final response = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 12));

    final body = response.body;

    // Already JSON → no challenge
    if (body.trimLeft().startsWith('{') || body.trimLeft().startsWith('[')) {
      return;
    }

    // Challenge page → extract a, b, c and decrypt
    final cookie = _solveAesChallenge(body);
    if (cookie == null) {
      throw Exception(
        'Could not solve host challenge (aes.js). '
        'Response starts with: ${body.substring(0, body.length.clamp(0, 120))}',
      );
    }

    _testCookie = cookie;
    debugPrint('[Signaling] Challenge solved, __test cookie set');
  }

  /// Parses the HTML challenge and returns the decrypted __test cookie value.
  String? _solveAesChallenge(String html) {
    // Look for: var a=toNumbers("..."),b=toNumbers("..."),c=toNumbers("...")
    final aMatch = RegExp(r'a=toNumbers\("([0-9a-fA-F]+)"\)').firstMatch(html);
    final bMatch = RegExp(r'b=toNumbers\("([0-9a-fA-F]+)"\)').firstMatch(html);
    final cMatch = RegExp(r'c=toNumbers\("([0-9a-fA-F]+)"\)').firstMatch(html);

    if (aMatch == null || bMatch == null || cMatch == null) {
      debugPrint('[Signaling] Could not find a/b/c in challenge HTML');
      return null;
    }

    final key = Uint8List.fromList(hex.decode(aMatch.group(1)!));
    final iv = Uint8List.fromList(hex.decode(bMatch.group(1)!));
    final cipher = Uint8List.fromList(hex.decode(cMatch.group(1)!));

    try {
      final cipherEngine = CBCBlockCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(key), iv));

      final decrypted = Uint8List(cipher.length);
      var offset = 0;
      while (offset < cipher.length) {
        offset += cipherEngine.processBlock(cipher, offset, decrypted, offset);
      }

      // Result is 16 bytes → hex string (the __test value)
      return hex.encode(decrypted);
    } catch (e) {
      debugPrint('[Signaling] AES decrypt failed: $e');
      return null;
    }
  }

  // Normal send / poll (with automatic re-solve if cookie expires)

  Future<Map<String, dynamic>> send(
    String event, [
    dynamic data,
    String? target,
  ]) async {
    await _ensureChallengeSolved();

    final uri = Uri.parse(baseUrl).replace(queryParameters: {
      'action': 'send',
      'room': room,
      'client': clientId,
    });

    final bodyMap = {
      'event': event,
      'data': data,
      'target': target,
    };

    debugPrint('[Signaling] SEND $event target=$target');

    var response = await http
        .post(
          uri,
          headers: _headers,
          body: jsonEncode(bodyMap),
        )
        .timeout(const Duration(seconds: 12));

    // Cookie expired → re-solve and retry once
    if (_isChallengeHtml(response.body)) {
      _testCookie = null;
      await _ensureChallengeSolved();
      response = await http
          .post(
            uri,
            headers: _headers,
            body: jsonEncode(bodyMap),
          )
          .timeout(const Duration(seconds: 12));
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Signaling send failed (${response.statusCode}): ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Future<void> poll() async {
    if (!_running) return;

    try {
      await _ensureChallengeSolved();

      final uri = Uri.parse(baseUrl).replace(queryParameters: {
        'action': 'poll',
        'room': room,
        'client': clientId,
        '_': DateTime.now().millisecondsSinceEpoch.toString(),
      });

      var response = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 12));

      if (_isChallengeHtml(response.body)) {
        _testCookie = null;
        await _ensureChallengeSolved();
        response = await http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 12));
      }

      if (response.statusCode != 200) {
        debugPrint('[Signaling] poll status ${response.statusCode}');
        return;
      }

      final body = response.body.trimLeft();
      if (!body.startsWith('{') && !body.startsWith('[')) {
        debugPrint(
            '[Signaling] poll non-JSON: ${body.substring(0, body.length.clamp(0, 80))}');
        return;
      }

      final decoded = jsonDecode(response.body);
      final list =
          decoded is Map<String, dynamic> && decoded['messages'] is List
              ? decoded['messages'] as List<dynamic>
              : const <dynamic>[];

      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final message = SignalMessage.fromJson(item);
        if (message.id.isEmpty) continue;
        if (!_processedIds.add(message.id)) continue;

        debugPrint(
          '[Signaling] RECV ${message.event} from=${message.client} target=${message.target}',
        );

        if (!_messages.isClosed) _messages.add(message);
      }
    } catch (e) {
      debugPrint('[Signaling] poll error: $e');
    }
  }

  bool _isChallengeHtml(String body) {
    final t = body.trimLeft().toLowerCase();
    return t.startsWith('<html') ||
        t.contains('aes.js') ||
        t.contains('tonumbers');
  }
}