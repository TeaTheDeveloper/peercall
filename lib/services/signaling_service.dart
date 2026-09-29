import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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
  static const Duration pollInterval = Duration(seconds: 5);

  final String room;
  final String clientId = _makeClientId();
  Timer? _timer;
  bool _running = false;
  final Set<String> _processedIds = <String>{};

  final StreamController<SignalMessage> _messages =
      StreamController<SignalMessage>.broadcast();
  Stream<SignalMessage> get messages => _messages.stream;

  SignalingService(this.room);

  static String _makeClientId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return 'mobile_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<void> start({required String role}) async {
    if (_running) return;
    _running = true;
    await send('join', {'joinedAt': DateTime.now().millisecondsSinceEpoch, 'role': role});
    _timer = Timer.periodic(pollInterval, (_) => poll());
    await poll();
  }

  Future<void> stop({required bool announceLeave, required bool hostEnded}) async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;

    if (announceLeave) {
      try {
        await send('leave', {'hostEnded': hostEnded});
      } catch (e) {
        debugPrint('Failed to announce leave: $e');
      }
    }

    await _messages.close();
  }

  Future<Map<String, dynamic>> send(
    String event, [
    dynamic data,
    String? target,
  ]) async {
    final uri = Uri.parse(baseUrl).replace(queryParameters: {
      'action': 'send',
      'room': room,
      'client': clientId,
    });

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'event': event,
        'data': data,
        'target': target,
      }),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Signaling request failed (${response.statusCode})');
    }

    final decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Future<void> poll() async {
    if (!_running) return;

    try {
      final uri = Uri.parse(baseUrl).replace(queryParameters: {
        'action': 'poll',
        'room': room,
        'client': clientId,
        '_': DateTime.now().millisecondsSinceEpoch.toString(),
      });

      debugPrint('Polling signaling server: $uri');

      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;

      final decoded = jsonDecode(response.body);
      final messages = decoded is Map<String, dynamic> && decoded['messages'] is List
          ? decoded['messages'] as List<dynamic>
          : const <dynamic>[];

      for (final item in messages) {
        if (item is! Map<String, dynamic>) continue;
        final message = SignalMessage.fromJson(item);
        if (message.id.isEmpty || !_processedIds.add(message.id)) continue;
        if (!_messages.isClosed) _messages.add(message);
      }
    } catch (e) {
      // Temporary network failures are expected; the next poll retries.
      debugPrint('Signaling poll failed: $e');
    }
  }
}
