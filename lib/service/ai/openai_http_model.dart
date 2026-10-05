import 'dart:convert';
import 'package:anx_reader/utils/log/common.dart';

import 'package:anx_reader/enums/ai_reasoning_effort.dart';
import 'package:http/http.dart' as http;
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/language_models.dart';
import 'package:langchain_core/prompts.dart';
import 'package:langchain_openai/langchain_openai.dart';

import 'chat_session.dart';
import 'langchain_ai_config.dart';
import 'openai_codec.dart';

/// 使用共同的 BaseChatModel 单轮接口，让两个 OpenAI 协议复用同一工具循环。
class OpenAiHttpModel extends BaseChatModel<ChatOpenAIOptions> {
  OpenAiHttpModel(
      {required this.config,
      required this.responses,
      required this.session,
      http.Client? client})
      : _client = client ?? http.Client(),
        _reasoning = session.reasoning,
        _priority = session.priority,
        super(defaultOptions: config.toOpenAIOptions());

  final LangchainAiConfig config;
  final bool responses;
  final AiChatSession session;
  final http.Client _client;
  AiReasoningEffort _reasoning;
  bool _priority;
  bool _initialized = false;
  bool _closed = false;
  bool _requestProduced = false;
  final List<Map<String, dynamic>> _items = [];
  final Set<String> _toolOutputs = {};

  @override
  String get modelType => responses ? 'openai-responses' : 'openai-chat';

  @override
  Future<List<int>> tokenize(PromptValue promptValue,
          {ChatOpenAIOptions? options}) =>
      ChatOpenAI(defaultOptions: defaultOptions)
          .tokenize(promptValue, options: options);

  @override
  Future<ChatResult> invoke(PromptValue input,
      {ChatOpenAIOptions? options}) async {
    ChatResult? result;
    await for (final chunk in stream(input, options: options)) {
      result = result == null ? chunk : result.concat(chunk);
    }
    return result!;
  }

  Map<String, dynamic> _request(
      List<ChatMessage> messages, ChatOpenAIOptions options) {
    final specs = options.tools ?? [];
    final tools = specs.map((tool) {
      final function = {
        'name': tool.name,
        'description': tool.description,
        'parameters': tool.inputJsonSchema,
        'strict': false
      };
      return responses
          ? {'type': 'function', ...function}
          : {'type': 'function', 'function': function};
    }).toList();
    if (responses) {
      if (!_initialized) {
        _items.addAll(AiChatSession.cloneItems(session.nativeItems));
        if (_items.isEmpty) {
          _items.addAll(messages
              .where((m) => m is! SystemChatMessage)
              .map(responseInputMessage));
          _toolOutputs.addAll(
              messages.whereType<ToolChatMessage>().map((m) => m.toolCallId));
        } else {
          _items.add(responseInputMessage(
              messages.lastWhere((m) => m is HumanChatMessage)));
        }
        _initialized = true;
      }
      for (final message in messages.whereType<ToolChatMessage>()) {
        if (_toolOutputs.add(message.toolCallId)) {
          _items.add(responseInputMessage(message));
        }
      }
    }
    return {
      'model': config.model,
      'stream': true,
      if (responses) ...{
        'store': false,
        'input': _items,
        'include': ['reasoning.encrypted_content'],
        'instructions': messages
            .whereType<SystemChatMessage>()
            .map((m) => m.content)
            .join('\n'),
        if (config.maxOutputTokens ?? config.maxTokens case final int limit)
          'max_output_tokens': limit,
        if (_reasoning != AiReasoningEffort.auto)
          'reasoning': {'effort': _reasoning.code},
      } else ...{
        'messages': messages.map(chatCompletionMessage).toList(),
        if (config.maxTokens != null) 'max_tokens': config.maxTokens,
        if (_reasoning != AiReasoningEffort.auto)
          'reasoning_effort': _reasoning.code,
      },
      if (_priority) 'service_tier': 'priority',
      if (config.temperature != null) 'temperature': config.temperature,
      if (config.topP != null) 'top_p': config.topP,
      if (tools.isNotEmpty) 'tools': tools,
    };
  }

  @override
  Stream<ChatResult> stream(PromptValue input,
      {ChatOpenAIOptions? options}) async* {
    var produced = false;
    final removed = <String>{};
    while (!_closed) {
      try {
        final body =
            _request(input.toChatMessages(), options ?? defaultOptions);
        await for (final event in _send(body)) {
          produced = produced ||
              event.output.content.isNotEmpty ||
              event.output.reasoningContent.isNotEmpty ||
              event.output.toolCalls.isNotEmpty;
          yield event;
        }
        if (_closed) return;
        session.reasoning = _reasoning;
        session.priority = _priority;
        return;
      } on OpenAiRequestError catch (error) {
        final rejected = error.rejectedOptions
            .where((key) =>
                !removed.contains(key) &&
                (key == 'priority'
                    ? _priority
                    : _reasoning != AiReasoningEffort.auto))
            .toSet();
        if (produced || _requestProduced || rejected.isEmpty || _closed) {
          rethrow;
        }
        AnxLog.warning(
            'OpenAI parameter fallback (${responses ? 'Responses' : 'Chat Completions'}): ${rejected.join(', ')}; HTTP ${error.status}, code=${error.error['code']}');
        removed.addAll(rejected);
        if (rejected.contains('priority')) _priority = false;
        if (rejected.contains('reasoning')) {
          _reasoning = AiReasoningEffort.auto;
        }
      } catch (_) {
        // 关闭 HTTP 连接会产生传输异常，主动停止应安静结束。
        if (_closed) return;
        rethrow;
      }
    }
  }

  ChatResult _chunk(
          {String text = '',
          String reasoning = '',
          List<AIChatMessageToolCall> calls = const []}) =>
      ChatResult(
        id: '',
        output: AIChatMessage(
            content: text, reasoningContent: reasoning, toolCalls: calls),
        finishReason: FinishReason.unspecified,
        metadata: const {},
        usage: const LanguageModelUsage(),
        streaming: true,
      );

  Stream<ChatResult> _send(Map<String, dynamic> body) async* {
    _requestProduced = false;
    final base = openAiBaseUrl(config.baseUrl ?? 'https://api.openai.com/v1');
    final request = http.Request('POST',
        Uri.parse('$base/${responses ? 'responses' : 'chat/completions'}'))
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey}',
        ...config.headers
      })
      ..body = jsonEncode(body);
    final response =
        await _client.send(request).timeout(const Duration(seconds: 90));
    if (response.statusCode >= 400) {
      final raw = await response.stream.bytesToString();
      Map<String, dynamic> error;
      try {
        final data = jsonDecode(raw) as Map;
        error = Map<String, dynamic>.from(
            data['error'] is Map ? data['error'] as Map : data);
      } catch (_) {
        error = {'message': raw};
      }
      throw OpenAiRequestError(response.statusCode, error);
    }
    final Stream<Map<String, dynamic>> events;
    if ((response.headers['content-type'] ?? '').contains('application/json')) {
      final data = Map<String, dynamic>.from(
          jsonDecode(await response.stream.bytesToString()) as Map);
      events = Stream.value(
          responses ? {'type': 'response.completed', 'response': data} : data);
    } else {
      events = decodeOpenAiSse(response.stream);
    }
    var completed = false;
    var textSeen = false;
    var reasoningSeen = false;
    final calls = <int, Map<String, String>>{};
    // 部分网关的结束帧省略 output，完整原生项已在 output_item.done 返回。
    final completedItems = <int, Map<String, dynamic>>{};
    await for (final event in events.timeout(const Duration(seconds: 120))) {
      if (_closed) return;
      if (event['error'] is Map ||
          event['type'] == 'response.failed' ||
          event['type'] == 'error') {
        final raw =
            event['error'] ?? (event['response'] as Map?)?['error'] ?? event;
        final error = Map<String, dynamic>.from(raw as Map);
        final status = (error['status'] ?? event['status']) as int?;
        throw OpenAiRequestError(status ?? 400, error);
      }
      if (responses) {
        final type = event['type'];
        if (type == 'response.output_item.done') {
          completedItems[event['output_index'] as int] =
              Map<String, dynamic>.from(event['item'] as Map);
        } else if (type == 'response.output_text.delta' ||
            type == 'response.refusal.delta') {
          textSeen = true;
          _requestProduced = true;
          yield _chunk(text: event['delta'] as String? ?? '');
        } else if (type == 'response.reasoning_summary_text.delta') {
          reasoningSeen = true;
          _requestProduced = true;
          yield _chunk(reasoning: event['delta'] as String? ?? '');
        } else if (type == 'response.function_call_arguments.delta' ||
            (type == 'response.output_item.added' &&
                (event['item'] as Map?)?['type'] == 'function_call')) {
          _requestProduced = true;
        } else if (type == 'response.incomplete') {
          throw StateError(
              'Response incomplete: ${(event['response'] as Map?)?['incomplete_details']}');
        } else if (type == 'response.completed') {
          final result = event['response'] as Map;
          if (result['status'] != null && result['status'] != 'completed') {
            throw StateError('Response ${result['status']}');
          }
          final finalOutput = result['output'] as List? ?? [];
          final indices = completedItems.keys.toList()..sort();
          final output = AiChatSession.cloneItems(finalOutput.isNotEmpty
              ? finalOutput
              : indices.map((i) => completedItems[i]!).toList());
          final toolCalls = <AIChatMessageToolCall>[];
          for (final item in output) {
            if (item['type'] == 'function_call') {
              toolCalls.add(_call('${item['call_id']}', '${item['name']}',
                  '${item['arguments']}'));
            } else if (item['type'] == 'message' && !textSeen) {
              for (final part in item['content'] as List? ?? []) {
                yield _chunk(
                    text: part['text'] as String? ??
                        part['refusal'] as String? ??
                        '');
              }
            } else if (item['type'] == 'reasoning' && !reasoningSeen) {
              for (final part in item['summary'] as List? ?? []) {
                yield _chunk(reasoning: part['text'] as String? ?? '');
              }
            }
          }
          _items.addAll(output);
          session.nativeItems = AiChatSession.cloneItems(_items);
          yield _chunk(calls: toolCalls);
          completed = true;
          break;
        }
      } else {
        final choices = event['choices'] as List? ?? [];
        if (choices.isEmpty) continue;
        final choice = choices.first as Map;
        final delta = (choice['delta'] ?? choice['message'] ?? {}) as Map;
        final text = delta['content'] as String? ?? '';
        final reasoning = delta['reasoning_content'] as String? ?? '';
        if (text.isNotEmpty || reasoning.isNotEmpty) {
          _requestProduced = true;
          yield _chunk(text: text, reasoning: reasoning);
        }
        var fallbackIndex = 0;
        for (final call in delta['tool_calls'] as List? ?? []) {
          _requestProduced = true;
          final index = call['index'] as int? ?? fallbackIndex++;
          final current = calls.putIfAbsent(
              index, () => {'id': '', 'name': '', 'arguments': ''});
          final function = call['function'] as Map? ?? {};
          for (final key in ['id', 'name', 'arguments']) {
            current[key] =
                '${current[key]}${key == 'id' ? call[key] ?? '' : function[key] ?? ''}';
          }
        }
        final finish = choice['finish_reason'];
        if (finish != null) {
          if (finish != 'stop' &&
              finish != 'tool_calls' &&
              finish != 'function_call') {
            throw StateError('Completion stopped: $finish');
          }
          completed = true;
          break;
        }
      }
    }
    if (!completed && !_closed) {
      throw StateError('AI stream ended before completion');
    }
    if (!responses && !_closed) {
      final indices = calls.keys.toList()..sort();
      yield _chunk(
          calls: indices
              .map((i) => _call(calls[i]!['id']!, calls[i]!['name']!,
                  calls[i]!['arguments']!))
              .toList());
    }
  }

  AIChatMessageToolCall _call(String id, String name, String raw) =>
      AIChatMessageToolCall(
        id: id,
        name: name,
        argumentsRaw: raw,
        arguments: Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );

  @override
  void close() {
    _closed = true;
    _client.close();
  }
}
