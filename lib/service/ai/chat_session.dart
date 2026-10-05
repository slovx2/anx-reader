import 'dart:convert';
import 'dart:async';
import 'package:anx_reader/utils/ai_reasoning_parser.dart';

import 'package:anx_reader/enums/ai_reasoning_effort.dart';

enum AiRunStatus { idle, running, completed, failed, cancelled }

/// 模型上下文和展示文本分开存储；检查点使用聊天消息数量定位。
class AiChatSession {
  String? identity;
  AiReasoningEffort reasoning = AiReasoningEffort.auto;
  bool priority = false;
  AiRunStatus status = AiRunStatus.idle;
  final Completer<void> _cancelled = Completer<void>();
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    status = AiRunStatus.cancelled;
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  List<Map<String, dynamic>> nativeItems = [];
  final Map<int, List<Map<String, dynamic>>> checkpoints = {};
  final Map<String, Map<String, dynamic>> citations = {};

  void configure(String key, AiReasoningEffort defaultReasoning) {
    if (identity == key) return;
    identity = key;
    reasoning = defaultReasoning;
    priority = false;
    nativeItems = [];
    checkpoints.clear();
  }

  void checkpoint(int messageCount) {
    checkpoints[messageCount] = cloneItems(nativeItems);
  }

  void rewind(int messageCount) {
    nativeItems = cloneItems(checkpoints[messageCount] ?? []);
    checkpoints.removeWhere((key, _) => key > messageCount);
  }

  Map<String, dynamic> toJson() => {
        'identity': identity,
        'reasoning': reasoning.code,
        'priority': priority,
        'status': status.name,
        'nativeItems': cloneItems(nativeItems),
        'checkpoints': checkpoints.map((k, v) => MapEntry('$k', cloneItems(v))),
        'citations': jsonDecode(jsonEncode(citations)),
      };

  AiChatSession();

  factory AiChatSession.fromJson(Map<String, dynamic>? json) {
    final session = AiChatSession();
    if (json == null) return session;
    session.identity = json['identity'] as String?;
    session.reasoning =
        AiReasoningEffort.fromCode(json['reasoning'] as String?);
    session.priority = json['priority'] == true;
    session.status = AiRunStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => AiRunStatus.idle,
    );
    session.nativeItems = cloneItems(json['nativeItems'] as List? ?? []);
    for (final entry in (json['checkpoints'] as Map? ?? {}).entries) {
      final index = int.tryParse(entry.key.toString());
      if (index != null) {
        session.checkpoints[index] = cloneItems(entry.value as List);
      }
    }
    for (final entry in (json['citations'] as Map? ?? {}).entries) {
      session.citations[entry.key.toString()] =
          Map<String, dynamic>.from(entry.value as Map);
    }
    if (session.status == AiRunStatus.running) {
      session.status = AiRunStatus.cancelled;
      session.nativeItems = [];
    }
    return session;
  }

  static List<Map<String, dynamic>> cloneItems(List items) =>
      (jsonDecode(jsonEncode(items)) as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
}

class AiChatEvent {
  AiChatEvent(this.content, AiChatSession session)
      : status = session.status,
        reasoning = session.reasoning,
        priority = session.priority,
        protocolState = Map.unmodifiable({
          'identity': session.identity,
          'nativeItems': List.unmodifiable(session.nativeItems),
        }),
        citations = Map.unmodifiable(session.citations);
  final String content;
  final AiRunStatus status;
  final AiReasoningEffort reasoning;
  final bool priority;
  final Map<String, dynamic> protocolState;
  late final ParsedReasoning display = parseReasoningContent(content);
  List<ParsedToolStep> get tools => display.toolSteps;
  final Map<String, Map<String, dynamic>> citations;
}
