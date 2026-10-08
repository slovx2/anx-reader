import 'dart:async';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/providers/ai_history.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/ai/ai_history.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/utils/ai_reasoning_parser.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/enums/ai_reasoning_effort.dart';
import 'package:anx_reader/providers/ai_providers.dart';
import 'package:anx_reader/service/ai/chat_session.dart';

part 'ai_chat.g.dart';

@Riverpod(keepAlive: true)
class AiChat extends _$AiChat {
  String? _currentSessionId;
  AiChatSession session = AiChatSession();
  Completer<void>? _runCompletion;
  bool get isRunning =>
      session.status == AiRunStatus.running ||
      _runCompletion?.isCompleted == false;

  /// 本轮是否在阅读页内发起；退出阅读页时只停止这类运行。
  bool _runStartedInReader = false;

  Future<void> stop() async {
    cancelActiveAiRequest(session);
    await _runCompletion?.future;
  }

  Future<void> stopReaderRun() async {
    if (!isRunning || !_runStartedInReader) return;
    await stop();
  }

  void configure(AiProvider provider) {
    session.configure(
        '${provider.id}|${provider.protocol.code}|${provider.url}|${provider.model}',
        provider.reasoningEffort);
  }

  Future<void> setOptions(AiProvider provider,
      {AiReasoningEffort? reasoning, bool? priority}) async {
    if (isRunning) return;
    configure(provider);
    if (reasoning != null) session.reasoning = reasoning;
    if (priority != null) session.priority = priority;
    ref.notifyListeners();
    final entries = ref.read(aiHistoryProvider).value ?? [];
    for (final entry in entries) {
      if (entry.id == _currentSessionId) {
        await ref.read(aiHistoryProvider.notifier).upsert(entry.copyWith(
              sessionData: session.toJson(),
              serviceId: provider.id,
              model: provider.model,
            ));
        break;
      }
    }
  }

  @override
  FutureOr<List<ChatMessage>> build() async {
    _currentSessionId = null;
    return List<ChatMessage>.empty();
  }

  Future<void> sendMessage(String message) async {
    state = AsyncData([
      ...state.whenOrNull(data: (data) => data) ?? [],
      ChatMessage.humanText(message),
    ]);
  }

  void restore(List<ChatMessage> history, {String? sessionId}) {
    if (sessionId != null) {
      _currentSessionId = sessionId;
    }
    state = AsyncData(history);
    session.rewind(history.length);
  }

  /// 由 provider 自己驱动整轮运行，不依赖聊天界面的生命周期。
  Future<void> send(String message) async {
    if (isRunning) return;
    _runStartedInReader = ref.read(currentReadingProvider).isReading;
    final sessionId = _ensureSessionId();
    final serviceId = Prefs().selectedAiService;
    final provider =
        ref.read(aiProvidersProvider.notifier).getSelectedProvider();
    if (provider != null) configure(provider);
    final model = provider?.model ?? '';
    final runSession = AiChatSession.fromJson(session.toJson());
    session = runSession;
    final historyLength = state.value?.length ?? 0;
    runSession.checkpoint(historyLength);
    runSession.status = AiRunStatus.running;
    final historyNotifier = ref.read(aiHistoryProvider.notifier);
    final initialHistoryState = ref
        .read(aiHistoryProvider)
        .maybeWhen(data: (value) => value, orElse: () => const []);
    AiChatHistoryEntry? entry;
    for (final item in initialHistoryState) {
      if (item.id == sessionId) {
        entry = item;
        break;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;

    List<ChatMessage> messages = [
      ...state.whenOrNull(data: (data) => data) ?? [],
      ChatMessage.humanText(message),
    ];

    state = AsyncData(messages);

    List<ChatMessage> updatedMessages = [
      ...messages,
      ChatMessage.ai(''),
    ];

    final draftEntry = (entry ??
            AiChatHistoryEntry(
              id: sessionId,
              serviceId: serviceId,
              model: model,
              createdAt: entry?.createdAt ?? now,
              updatedAt: now,
              messages: List<ChatMessage>.from(updatedMessages),
              completed: false,
            ))
        .copyWith(
      messages: List<ChatMessage>.from(updatedMessages),
      updatedAt: now,
      completed: false,
      model: model,
      serviceId: provider?.id ?? serviceId,
      sessionData: runSession.toJson(),
    );

    String assistantResponse = "";
    final runCompletion = _runCompletion = Completer<void>();
    try {
      await historyNotifier.upsert(draftEntry);
      if (identical(session, runSession)) state = AsyncData(updatedMessages);
      if (runSession.status == AiRunStatus.cancelled) return;
      await for (final event in aiChatEvents(
        messages,
        ref: ref.container,
        session: runSession,
      )) {
        assistantResponse = event.content;

        final updatedMessagesWithResponse =
            List<ChatMessage>.from(updatedMessages);
        updatedMessagesWithResponse[updatedMessagesWithResponse.length - 1] =
            assistantMessageFromDisplayContent(assistantResponse);

        updatedMessages = updatedMessagesWithResponse;
        if (identical(session, runSession)) state = AsyncData(updatedMessages);
      }
    } catch (error, stack) {
      if (runSession.status != AiRunStatus.cancelled) {
        runSession.status = AiRunStatus.failed;
      }
      AnxLog.severe('AI chat run failed: $error', error, stack);
    } finally {
      if (runSession.status == AiRunStatus.running) {
        runSession.cancel();
      }
      if (runSession.status != AiRunStatus.completed) {
        runSession.rewind(historyLength);
      }
      // 只提交完整协议回合；中断后下次从可见历史重建，不重放悬空工具调用。
      if (runSession.status != AiRunStatus.completed) {
        runSession.nativeItems = [];
      }
      final finalMessages = List<ChatMessage>.from(updatedMessages);
      if (runSession.status == AiRunStatus.completed) {
        runSession.checkpoint(finalMessages.length);
      }
      try {
        await historyNotifier.upsert(draftEntry.copyWith(
          messages: finalMessages,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          completed: runSession.status == AiRunStatus.completed,
          sessionData: runSession.toJson(),
        ));
      } finally {
        runCompletion.complete();
        if (identical(session, runSession)) ref.notifyListeners();
      }
    }
  }

  void clear() {
    state = AsyncData(List<ChatMessage>.empty());
    _currentSessionId = null;
    session = AiChatSession();
  }

  void loadHistoryEntry(AiChatHistoryEntry entry) {
    _currentSessionId = entry.id;
    session = AiChatSession.fromJson(entry.sessionData);
    final providers = ref.read(aiProvidersProvider.notifier);
    final provider = providers.getProviderById(entry.serviceId);
    if (provider != null) {
      providers.setSelectedProvider(entry.serviceId);
      if (entry.model.isNotEmpty && provider.model != entry.model) {
        providers.updateProvider(provider.copyWith(model: entry.model));
      }
    }
    state = AsyncData(List<ChatMessage>.from(entry.messages));
  }

  String? get currentSessionId => _currentSessionId;

  String _ensureSessionId() {
    return _currentSessionId ??= _generateSessionId();
  }

  String _generateSessionId() {
    return DateTime.now().microsecondsSinceEpoch.toString();
  }
}
