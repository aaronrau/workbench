import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final environment = Platform.environment;
  final port = int.parse(environment['MOCK_PORT'] ?? '8787');
  final agents = (environment['MOCK_AGENTS'] ?? 'Mock Agent')
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  final token = environment['MOCK_TOKEN'] ?? 'synthetic-token';
  final acknowledgementDelay = Duration(
    milliseconds: int.parse(environment['MOCK_ACK_DELAY_MS'] ?? '0'),
  );
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('mock_server_ready agents=${agents.length}');
  await for (final request in server) {
    if (request.uri.path != '/ws' || !_isAuthorized(request, token)) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      continue;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      _serveSocket(socket, agents, acknowledgementDelay);
    } on Object {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
    }
  }
}

bool _isAuthorized(HttpRequest request, String token) {
  final bearer = request.headers.value(HttpHeaders.authorizationHeader);
  final voiceToken = request.headers.value('X-Voice-Api-Token');
  return bearer == 'Bearer $token' || voiceToken == token;
}

void _serveSocket(
  WebSocket socket,
  List<String> agents,
  Duration acknowledgementDelay,
) {
  var eventId = 0;
  socket.add(
    jsonEncode(<String, Object>{
      'type': 'connection.ready',
      'version': 1,
      'agents': agents,
      'agent_controls': <String>['message.send', 'summary.request'],
      'session_controls': <String>[],
    }),
  );
  socket.listen((value) async {
    Object? decoded;
    try {
      decoded = jsonDecode('$value');
    } on Object {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    final type = decoded['type'];
    if (type == 'connection.resume') {
      return;
    }
    if (type == 'message.send') {
      final requestId = decoded['request_id'];
      final agent = decoded['agent'];
      final message = decoded['message'];
      if (requestId is! String || agent is! String || message is! String) {
        return;
      }
      stdout.writeln('signal_received characters=${message.length}');
      if (acknowledgementDelay > Duration.zero) {
        await Future<void>.delayed(acknowledgementDelay);
      }
      socket.add(
        jsonEncode(<String, Object>{
          'type': 'message.accepted',
          'request_id': requestId,
          'ok': true,
          'result': <String, Object>{'sent': true},
        }),
      );
      eventId++;
      socket.add(
        jsonEncode(<String, Object>{
          'type': 'message.progress',
          'event_id': eventId,
          'request_id': requestId,
          'agent': agent,
          'payload': <String, Object>{
            'message': 'Mock server received the signal.',
          },
        }),
      );
      return;
    }
    if (type == 'summary.request') {
      final requestId = decoded['request_id'];
      final agent = decoded['agent'];
      if (requestId is! String || agent is! String) {
        return;
      }
      eventId++;
      socket.add(
        jsonEncode(<String, Object>{
          'type': 'summary.result',
          'event_id': eventId,
          'request_id': requestId,
          'agent': agent,
          'result': <String, Object>{'summary': 'Mock server summary signal.'},
        }),
      );
    }
  });
}
