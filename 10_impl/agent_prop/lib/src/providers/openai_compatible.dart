import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cancellation.dart';
import '../config.dart';
import '../errors.dart';
import '../models.dart';
import '../plan_block.dart';
import '../reliability.dart';
import '../think_block.dart';
import 'provider.dart';

/// C2 adapter for any OpenAI-compatible chat-completions endpoint.
final class OpenAiCompatibleProvider implements Provider {
  OpenAiCompatibleProvider(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  final ProviderConfig config;
  final http.Client _client;

  @override
  Future<ProviderResponse> complete(
    ProviderRequest request, {
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
    CancelSignal? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) {
      throw const StepFailure.cancelled('cancelled by user');
    }
    final streaming = onDelta != null || onReasoning != null;
    final base = config.baseUrl!.replaceAll(RegExp(r'/+$'), '');
    final http.Request httpRequest;
    try {
      httpRequest = http.Request('POST', Uri.parse('$base/chat/completions'))
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode({
          'model': request.model,
          'messages': openAiMessages(request),
          'stream': streaming,
          if (request.tools.isNotEmpty) 'tools': _toolJson(request.tools),
          ...config.sampling?.openAiJson() ?? const {},
        });
    } on Object catch (e) {
      throw StepFailure.unrecoverable('provider request failed: $e');
    }
    if (config.apiKey != null) {
      httpRequest.headers['authorization'] = 'Bearer ${config.apiKey}';
    }

    final http.StreamedResponse response;
    try {
      response =
          await raceCancel(_client.send(httpRequest), cancel).timeout(kModelTimeout);
    } on TimeoutException {
      throw const StepFailure.timeout('model call timed out');
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw StepFailure.unrecoverable(
          'provider HTTP ${response.statusCode}: $body');
    }
    if (!streaming) {
      final decoded =
          jsonDecode(await response.stream.bytesToString()) as Map<String, dynamic>;
      final message =
          ((decoded['choices'] as List).first as Map)['message'] as Map;
      return parseCompletion(_completion(message.cast<String, dynamic>()));
    }
    return _stream(response, onDelta, onReasoning, cancel);
  }

  Future<ProviderResponse> _stream(
    http.StreamedResponse response,
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
    CancelSignal? cancel,
  ) async {
    final think = ThinkTextStream();
    final text = PlanTextStream();
    final calls = <int, _CallBuilder>{};
    final lines = raceCancelStream(
      response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(kModelTimeout),
      cancel,
    );
    try {
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') continue;
        final decoded = jsonDecode(data) as Map<String, dynamic>;
        final choice = (decoded['choices'] as List).first as Map;
        final delta =
            (choice['delta'] as Map?)?.cast<String, dynamic>() ?? const {};
        final content = delta['content'] as String?;
        if (content != null && content.isNotEmpty) {
          final thinkChunk = think.add(content);
          if (thinkChunk.reasoning.isNotEmpty) {
            onReasoning?.call(thinkChunk.reasoning);
          }
          if (thinkChunk.visible.isNotEmpty) {
            final chunk = text.add(thinkChunk.visible);
            if (chunk.isNotEmpty) onDelta?.call(chunk);
          }
        }
        for (final raw in (delta['tool_calls'] as List? ?? const [])) {
          final tc = (raw as Map).cast<String, dynamic>();
          final builder = calls.putIfAbsent(
              (tc['index'] as int?) ?? 0, () => _CallBuilder());
          // MiniMax (and possibly other vendors) repeat the call on later
          // chunks with empty strings for id/name; merge only non-empty
          // values so the first chunk's id and name survive to the end.
          final id = tc['id'];
          if (id is String && id.isNotEmpty) builder.id = id;
          final fn = (tc['function'] as Map?)?.cast<String, dynamic>();
          if (fn != null) {
            final name = fn['name'];
            if (name is String && name.isNotEmpty) builder.name = name;
            final args = fn['arguments'];
            if (args is String) builder.arguments.write(args);
          }
        }
      }
    } on TimeoutException {
      throw const StepFailure.timeout('model stream timed out');
    }
    final lastThink = think.flush();
    if (lastThink.reasoning.isNotEmpty) {
      onReasoning?.call(lastThink.reasoning);
    }
    if (lastThink.visible.isNotEmpty) {
      final chunk = text.add(lastThink.visible);
      if (chunk.isNotEmpty) onDelta?.call(chunk);
    }
    final tail = text.flush();
    if (tail.isNotEmpty) onDelta?.call(tail);
    final parsed = parsePlanBlock(text.raw);
    return parseCompletion(Completion(
      text: parsed.text,
      toolCalls: _toolCalls(calls),
      plan: parsed.plan,
      reasoning: think.reasoning,
    ));
  }

  List<Map<String, dynamic>> _toolJson(List<ToolDefinition> tools) => [
        for (final tool in tools)
          {
            'type': 'function',
            'function': {
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
          }
      ];

  Completion _completion(Map<String, dynamic> message) {
    final toolCalls = <ToolCall>[];
    for (final call in (message['tool_calls'] as List? ?? const [])) {
      final map = (call as Map).cast<String, dynamic>();
      final function = (map['function'] as Map).cast<String, dynamic>();
      final raw = function['arguments'];
      final arguments = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : (raw as Map).cast<String, dynamic>();
      toolCalls.add(ToolCall(
        id: map['id'] as String?,
        name: function['name'] as String,
        arguments: arguments,
      ));
    }
    final think = parseThinkBlock(message['content'] as String? ?? '');
    final parsed = parsePlanBlock(think.text);
    return Completion(
      text: parsed.text,
      toolCalls: toolCalls,
      plan: parsed.plan,
      reasoning: think.reasoning,
    );
  }
}

final class _CallBuilder {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

List<ToolCall> _toolCalls(Map<int, _CallBuilder> calls) => [
      for (final index in calls.keys.toList()..sort())
        ToolCall(
          id: calls[index]!.id,
          name: calls[index]!.name ?? '',
          arguments: _decodeArguments(calls[index]!.arguments.toString()),
        ),
    ];

Map<String, dynamic> _decodeArguments(String raw) {
  if (raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded.cast<String, dynamic>() : const {};
  } on FormatException {
    return const {};
  }
}

/// Map the transcript to OpenAI chat messages. Only observations bound to a
/// tool call present in this same request are sent as `role: tool`; other
/// observations (e.g. a provider timeout) are sent as user messages, since a
/// tool result without a matching tool call is rejected by the API.
List<Map<String, dynamic>> openAiMessages(ProviderRequest request) {
  final out = <Map<String, dynamic>>[
    {'role': 'system', 'content': request.system},
  ];
  var counter = 0;
  final toolCallIds = <String>{};
  for (final entry in request.messages) {
    switch (entry) {
      case UserEntry(:final text):
        out.add({'role': 'user', 'content': text});
      case AssistantEntry(:final thought, :final action):
        switch (action) {
          case ToolBatch(:final calls)
              when calls.isNotEmpty && calls.every((c) => c.name.isNotEmpty):
            // One assistant message carries the whole batch; each tool result
            // follows as its own `role: tool` message, paired by id.
            final batch = <Map<String, dynamic>>[];
            for (final call in calls) {
              final callId = call.id ?? 'call_${counter++}';
              toolCallIds.add(callId);
              batch.add({
                'id': callId,
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': jsonEncode(call.arguments),
                },
              });
            }
            out.add({
              'role': 'assistant',
              'content': thought,
              'tool_calls': batch,
            });
          case ToolBatch():
            // A batch containing a call with no name cannot be replayed as
            // tool calls: the API rejects an empty `function.name`. Keep it as
            // plain assistant text so the request stays valid and the model
            // can retry.
            out.add({'role': 'assistant', 'content': thought});
          case Finish():
            out.add({'role': 'assistant', 'content': thought});
        }
      case ObservationEntry(:final text, :final toolCallId):
        if (toolCallId != null && toolCallIds.contains(toolCallId)) {
          out.add({
            'role': 'tool',
            'tool_call_id': toolCallId,
            'content': text,
          });
        } else {
          out.add({'role': 'user', 'content': 'observation: $text'});
        }
    }
  }
  // Attach the goal's `@path` images (C7) to its user message as multimodal
  // content parts; older entries keep their text references only.
  if (request.images.isNotEmpty) {
    final lastUser = out.lastIndexWhere((message) => message['role'] == 'user');
    if (lastUser >= 0 && out[lastUser]['content'] is String) {
      out[lastUser]['content'] = [
        {'type': 'text', 'text': out[lastUser]['content'] as String},
        for (final image in request.images)
          if (ImageAttachment.mimeFor(image.path) case final mime?)
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:$mime;base64,${base64Encode(image.bytes)}',
              },
            },
      ];
    }
  }
  return out;
}
