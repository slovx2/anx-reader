import 'dart:async';
import 'dart:convert';

import 'package:langchain_core/chat_models.dart';

/// SSE 按 UTF-8 流解码后按行分帧，支持跨网络包的中文和多行 data。
Stream<Map<String, dynamic>> decodeOpenAiSse(Stream<List<int>> bytes) async* {
  final data = <String>[];
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isEmpty) continue;
      final payload = data.join('\n');
      data.clear();
      if (payload == '[DONE]') return;
      yield Map<String, dynamic>.from(jsonDecode(payload) as Map);
    } else if (line.startsWith('data:')) {
      data.add(line.substring(5).trimLeft());
    }
  }
  if (data.isNotEmpty && data.join('\n') != '[DONE]') {
    yield Map<String, dynamic>.from(jsonDecode(data.join('\n')) as Map);
  }
}

String openAiBaseUrl(String url) {
  final uri = Uri.parse(url.trim());
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isNotEmpty && segments.last == 'responses') {
    segments.removeLast();
  }
  if (segments.length >= 2 &&
      segments[segments.length - 2] == 'chat' &&
      segments.last == 'completions') {
    segments.removeRange(segments.length - 2, segments.length);
  }
  return uri
      .replace(pathSegments: segments, query: null, fragment: null)
      .toString()
      .replaceFirst(RegExp(r'/$'), '');
}

Map<String, dynamic> chatCompletionMessage(ChatMessage message) {
  if (message is ToolChatMessage) {
    return {
      'role': 'tool',
      'tool_call_id': message.toolCallId,
      'content': message.content
    };
  }
  return {
    'role': message is SystemChatMessage
        ? 'system'
        : message is AIChatMessage
            ? 'assistant'
            : 'user',
    'content': message.contentAsString,
    if (message is AIChatMessage && message.toolCalls.isNotEmpty)
      'tool_calls': message.toolCalls
          .map((call) => {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': call.argumentsRaw.isEmpty
                      ? jsonEncode(call.arguments)
                      : call.argumentsRaw
                },
              })
          .toList(),
  };
}

Map<String, dynamic> responseInputMessage(ChatMessage message) =>
    message is ToolChatMessage
        ? {
            'type': 'function_call_output',
            'call_id': message.toolCallId,
            'output': message.content
          }
        : {
            'role': message is AIChatMessage ? 'assistant' : 'user',
            'content': message.contentAsString
          };

class OpenAiRequestError implements Exception {
  OpenAiRequestError(this.status, this.error);
  final int status;
  final Map<String, dynamic> error;

  /// 只识别服务端明确的参数拒绝，不把普通 400、认证或容量错误当成能力探测。
  Set<String> get rejectedOptions {
    if (status != 400 && status != 422) return {};
    final code = '${error['code'] ?? ''}'.toLowerCase();
    final message = '${error['message'] ?? ''}'.toLowerCase();
    final param = '${error['param'] ?? ''}'.toLowerCase();
    final explicitlyUnsupported = code.contains('unsupported') ||
        RegExp(r'not supported|unsupported|does not support|unknown parameter|unrecognized|not permitted|not allowed')
            .hasMatch(message) ||
        (param.isNotEmpty &&
            (code == 'invalid_value' ||
                code == 'invalid_parameter' ||
                RegExp(r'invalid value|supported values|must be one of')
                    .hasMatch(message)));
    if (!explicitlyUnsupported) return {};
    final diagnostic = '$param $message';
    return {
      if (diagnostic.contains('reasoning_effort') ||
          diagnostic.contains('reasoning.effort') ||
          param == 'reasoning')
        'reasoning',
      if (diagnostic.contains('service_tier')) 'priority',
    };
  }

  @override
  String toString() => 'HTTP $status: ${error['message'] ?? error}';
}
