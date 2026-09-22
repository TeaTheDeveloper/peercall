import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

class SignalMessage {
  final String event;
  final dynamic data;
  final String client;

  SignalMessage({required this.event, required this.data, required this.client});

  factory SignalMessage.fromJson(Map<String, dynamic> json) {
    return SignalMessage(
      event: json['event']?.toString() ?? '',
      data: json['data'],
      client: json['client']?.toString() ?? '',
    );
  }
}

class SignalingService {
  static const String baseUrl = 'http://php-webrtc.unaux.com/home';
  static const Duration pollInterval = Duration(seconds: 1);

  final String room;
  final String clientId = _makeClientId();
  Timer? _timer;
  int _lastMessageId = 0;
  bool _running = false;

  final StreamController<SignalMessage> _messages = StreamController.broadcast();
  Stream<SignalMessage> get messages => _messages.stream;

  SignalingService(this.room);

  static String _makeClientId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return 'mobile_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await send('join');
    _timer = Timer.periodic(pollInterval, (_) => poll());
    await poll();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    try {
      await send('leave');
    } catch (_) {}
    await _messages.close();
  }

  Future<void> send(String event, [dynamic data]) async {
    final uri = Uri.parse(baseUrl).replace(queryParameters: {
      'action': 'send',
      'room': room,
      'client': clientId,
    });

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'event': event, 'data': data}),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Signaling request failed (${response.statusCode})');
    }
  }

  Future<void> poll() async {
    if (!_running) return;
    try {
      final uri = Uri.parse(baseUrl).replace(queryParameters: {
        'action': 'poll',
        'room': room,
        'client': clientId,
      });

      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;

      final decoded = jsonDecode(response.body);
      final List<dynamic> messages = decoded is List
          ? decoded
          : (decoded is Map<String, dynamic> && decoded['messages'] is List
              ? decoded['messages'] as List<dynamic>
              : const []);

      for (final item in messages) {
        if (item is! Map<String, dynamic>) continue;
        final id = int.tryParse(item['id']?.toString() ?? '') ?? 0;
        if (id <= _lastMessageId) continue;
        _lastMessageId = id;
        _messages.add(SignalMessage.fromJson(item));
      }
    } catch (_) {
      // Temporary network failures are expected; the next poll retries.
    }
  }
}
