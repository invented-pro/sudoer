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

/// C2 adapter for a local ollama server.
final class OllamaProvider implements Provider {
  OllamaProvider(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  final ProviderConfig config;
  final http.Client _client;

  String get _base =>
      (config.baseUrl ?? 'http://localhost:11434').replaceAll(RegExp(r'/+$'), '');

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
    final http.Request httpRequest;
    try {
      httpRequest = http.Request('POST', Uri.parse('$_base/api/chat'))
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode({
          'model': request.model,
          'stream': streaming,
          'messages': ollamaMessages(request),
          if (request.tools.isNotEmpty) 'tools': _toolJson(request.tools),
          if (config.sampling != null) 'options': config.sampling!.ollamaJson(),
        });
    } on Object catch (e) {
      throw StepFailure.unrecoverable('provider request failed: $e');
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
      final message = (decoded['message'] as Map).cast<String, dynamic>();
      return parseCompletion(_completion(message));
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
    final toolCalls = <ToolCall>[];
    final lines = raceCancelStream(
      response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(kModelTimeout),
      cancel,
    );
    try {
      await for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line) as Map<String, dynamic>;
        final message = (decoded['message'] as Map?)?.cast<String, dynamic>();
        final content = message?['content'] as String?;
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
        toolCalls.addAll(_parseToolCalls(message?['tool_calls']));
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
      toolCalls: toolCalls,
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
    final toolCalls = _parseToolCalls(message['tool_calls']);
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

List<ToolCall> _parseToolCalls(Object? raw) {
  final calls = <ToolCall>[];
  for (final call in (raw as List? ?? const [])) {
    final map = (call as Map).cast<String, dynamic>();
    final function = (map['function'] as Map).cast<String, dynamic>();
    final arguments = function['arguments'];
    calls.add(ToolCall(
      id: map['id'] as String?,
      name: function['name'] as String,
      arguments: arguments is Map ? arguments.cast<String, dynamic>() : const {},
    ));
  }
  return calls;
}

/// Map the transcript to ollama chat messages. Ollama pairs a tool result
/// positionally with the preceding tool call, so only an observation that
/// directly follows a tool call is sent as `role: tool`; others are sent as
/// user messages.
List<Map<String, dynamic>> ollamaMessages(ProviderRequest request) {
  final out = <Map<String, dynamic>>[
    {'role': 'system', 'content': request.system},
  ];
  var pendingTool = false;
  for (final entry in request.messages) {
    switch (entry) {
      case UserEntry(:final text):
        out.add({'role': 'user', 'content': text});
        pendingTool = false;
      case AssistantEntry(:final thought, :final action):
        switch (action) {
          case ToolBatch(:final calls) when calls.isNotEmpty:
            // One assistant message carries the whole batch; ollama pairs the
            // tool results positionally with the calls, so they follow in the
            // listed order.
            out.add({
              'role': 'assistant',
              'content': thought,
              'tool_calls': [
                for (final call in calls)
                  {
                    'function': {
                      'name': call.name,
                      'arguments': call.arguments,
                    }
                  }
              ],
            });
            pendingTool = true;
          case ToolBatch():
            // An empty batch is a degenerate action; replay it as text.
            out.add({'role': 'assistant', 'content': thought});
            pendingTool = false;
          case Finish():
            out.add({'role': 'assistant', 'content': thought});
            pendingTool = false;
        }
      case ObservationEntry(:final text):
        if (pendingTool) {
          out.add({'role': 'tool', 'content': text});
          pendingTool = false;
        } else {
          out.add({'role': 'user', 'content': 'observation: $text'});
        }
    }
  }
  // Attach the goal's `@path` images (C7) to its user message; older entries
  // keep their text references only.
  if (request.images.isNotEmpty) {
    final lastUser = out.lastIndexWhere((message) => message['role'] == 'user');
    if (lastUser >= 0) {
      out[lastUser]['images'] = [
        for (final image in request.images) base64Encode(image.bytes),
      ];
    }
  }
  return out;
}
