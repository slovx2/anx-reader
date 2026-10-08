import 'dart:async';
import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/providers/ai_providers.dart';
import 'package:anx_reader/service/ai/ai_key_rotator.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';
import 'package:anx_reader/service/ai/langchain_registry.dart';
import 'package:anx_reader/service/ai/langchain_runner.dart';
import 'package:anx_reader/utils/ai_reasoning_parser.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/prompts.dart';
import 'chat_session.dart';

final Map<AiChatSession, CancelableLangchainRunner> _activeRuns = {};

// Global request timestamps list for RPM throttling
final List<DateTime> _aiRequestTimestamps = [];

/// Throttle AI requests if RPM limit is configured (sliding 1-minute window).
Future<void> _throttleIfNeeded(AiChatSession session) async {
  final rpm = Prefs().aiRpm;
  if (rpm <= 0) return;
  final now = DateTime.now();
  final windowStart = now.subtract(const Duration(minutes: 1));
  _aiRequestTimestamps.removeWhere((ts) => ts.isBefore(windowStart));
  if (_aiRequestTimestamps.length >= rpm) {
    final oldest = _aiRequestTimestamps.first;
    final waitUntil = oldest.add(const Duration(minutes: 1));
    final waitDuration = waitUntil.difference(DateTime.now());
    if (waitDuration > Duration.zero) {
      await Future.any(
          [Future<void>.delayed(waitDuration), session.whenCancelled]);
      if (session.status == AiRunStatus.cancelled) return;
    }
    final newNow = DateTime.now();
    _aiRequestTimestamps.removeWhere(
        (ts) => ts.isBefore(newNow.subtract(const Duration(minutes: 1))));
  }
  _aiRequestTimestamps.add(DateTime.now());
}

Stream<String> aiGenerateStream(
  List<ChatMessage> messages, {
  String? identifier,
  Map<String, String>? config,
  bool regenerate = false,
  bool useAgent = false,
  ProviderContainer? ref,
  AiChatSession? session,
}) {
  if (useAgent) {
    assert(ref != null, 'ref must be provided when useAgent is true');
  }
  final registry = LangchainAiRegistry(ref, session: session);
  final runner = CancelableLangchainRunner();

  return _runGeneration(
      messages: messages,
      identifier: identifier,
      overrideConfig: config,
      regenerate: regenerate,
      useAgent: useAgent,
      registry: registry,
      runner: runner);
}

Stream<AiChatEvent> aiChatEvents(
  List<ChatMessage> messages, {
  required ProviderContainer ref,
  required AiChatSession session,
}) async* {
  session.status = AiRunStatus.running;
  var latestContent = '';
  await for (final content in aiGenerateStream(messages,
      useAgent: true, ref: ref, session: session)) {
    latestContent = content;
    yield AiChatEvent(content, session);
  }
  if (session.status == AiRunStatus.running) {
    session.status = AiRunStatus.completed;
  }
  yield AiChatEvent(latestContent, session);
}

void cancelActiveAiRequest(AiChatSession session) {
  session.cancel();
  _activeRuns[session]?.cancel();
}

Stream<String> _runGeneration({
  required List<ChatMessage> messages,
  String? identifier,
  Map<String, String>? overrideConfig,
  required bool regenerate,
  required bool useAgent,
  required LangchainAiRegistry registry,
  required CancelableLangchainRunner runner,
}) async* {
  final session = registry.session;
  _activeRuns[session] = runner;
  try {
    if (session.status == AiRunStatus.cancelled) return;
    final sanitizedMessages = _sanitizeMessagesForPrompt(messages);
    final notifier = registry.ref?.read(aiProvidersProvider.notifier);
    AiProvider? provider;
    if (overrideConfig == null) {
      if (notifier != null) {
        provider = identifier == null
            ? notifier.getSelectedProvider()
            : notifier.getProviderById(identifier);
      } else {
        final providers = Prefs()
            .getAiProviders()
            .map((json) => AiProvider.fromJson(json as Map<String, dynamic>))
            .toList();
        final selectedId = identifier ?? Prefs().selectedAiService;
        provider = providers.where((p) => p.id == selectedId).firstOrNull;
        if (identifier == null) {
          provider ??= providers.where((p) => p.enabled).firstOrNull;
        }
      }
    }
    late final LangchainPipeline pipeline;
    if (provider != null) {
      if (!provider.enabled || !AiKeyRotator.hasValidKey(provider)) {
        throw StateError('AI provider has no enabled API key');
      }
      final config = LangchainAiConfig.fromProvider(
        providerId: provider.id,
        model: provider.model,
        apiKey: AiKeyRotator.getNextKey(provider)!,
        url: provider.url,
        reasoningEffort: provider.reasoningEffort,
      );
      session.configure(
          '${provider.id}|${provider.protocol.code}|${provider.url}|${provider.model}',
          provider.reasoningEffort);
      pipeline = registry.resolveByProtocol(provider.protocol, config,
          useAgent: useAgent);
    } else {
      final selectedIdentifier = identifier ?? Prefs().selectedAiService;
      final saved = Prefs().getAiConfig(selectedIdentifier);
      if (saved.isEmpty && (overrideConfig == null || overrideConfig.isEmpty)) {
        throw StateError('AI service not configured');
      }
      var config = LangchainAiConfig.fromPrefs(selectedIdentifier, saved);
      if (overrideConfig != null && overrideConfig.isNotEmpty) {
        config = mergeConfigs(config,
            LangchainAiConfig.fromPrefs(selectedIdentifier, overrideConfig));
      }
      session.configure('$selectedIdentifier|${config.baseUrl}|${config.model}',
          config.reasoningEffort);
      pipeline = registry.resolve(config, useAgent: useAgent);
    }
    try {
      await _throttleIfNeeded(session);
      if (session.status == AiRunStatus.cancelled) return;
      yield* _executeStream(
        model: pipeline.model,
        pipeline: pipeline,
        sanitizedMessages: sanitizedMessages,
        useAgent: useAgent,
        session: session,
        runner: runner,
      );
    } finally {
      pipeline.model.close();
    }
    if (provider != null &&
        session.status != AiRunStatus.cancelled &&
        session.status != AiRunStatus.failed) {
      if (notifier != null) {
        notifier.advanceKeyIndex(provider.id);
      } else {
        final providers = Prefs()
            .getAiProviders()
            .map((json) => AiProvider.fromJson(json as Map<String, dynamic>));
        Prefs().saveAiProviders(providers
            .map((p) =>
                p.id == provider!.id ? p.copyWith(keyIndex: p.keyIndex + 1) : p)
            .toList());
      }
    }
  } catch (error, stack) {
    if (session.status != AiRunStatus.cancelled) {
      session.status = AiRunStatus.failed;
      AnxLog.severe('AI request failed: $error', error, stack);
      yield _mapError(error);
    }
  } finally {
    _activeRuns.remove(session);
  }
}

/// Execute the AI stream with the given model and pipeline
Stream<String> _executeStream({
  required BaseChatModel model,
  required LangchainPipeline pipeline,
  required List<ChatMessage> sanitizedMessages,
  required bool useAgent,
  required AiChatSession session,
  required CancelableLangchainRunner runner,
}) async* {
  Stream<String> stream;
  if (useAgent) {
    final inputMessage = _latestUserMessage(sanitizedMessages);
    if (inputMessage == null) {
      yield 'No user input provided';
      return;
    }

    final tools = pipeline.tools;

    final historyMessages = sanitizedMessages
        .sublist(0, sanitizedMessages.length - 1)
        .toList(growable: false);

    stream = runner.streamAgent(
      model: model,
      tools: tools,
      history: historyMessages,
      input: inputMessage,
      systemMessage: pipeline.systemMessage,
      session: session,
    );
  } else {
    final prompt = PromptValue.chat(sanitizedMessages);
    stream = runner.stream(model: model, prompt: prompt, session: session);
  }

  var buffer = '';

  try {
    await for (final chunk in stream) {
      buffer = chunk;
      yield buffer;
    }
  } catch (error, stack) {
    if (session.status == AiRunStatus.cancelled) return;
    session.status = AiRunStatus.failed;
    final mapped = _mapError(error);
    AnxLog.severe('AI error: $mapped\n$stack');
    yield buffer.isEmpty ? mapped : '$buffer\n\n$mapped';
  } finally {
    try {
      model.close();
    } catch (_) {}
  }
}

String _mapError(Object error) {
  final base = 'Error: ';

  if (error is TimeoutException) {
    return '${base}Request timed out';
  }

  if (error is SocketException) {
    return '${base}Network error: ${error.message}';
  }

  final message = error.toString().toLowerCase();

  if (message.contains('401') ||
      message.contains('unauthorized') ||
      message.contains('invalid api key')) {
    return '${base}Authentication failed. Please verify API key.';
  }

  if (message.contains('429') || message.contains('rate limit')) {
    return '${base}Rate limit reached. Try again later.';
  }

  if (message.contains('timeout')) {
    return '${base}Request timed out';
  }

  if (message.contains('network') ||
      message.contains('socket') ||
      message.contains('failed host lookup')) {
    return '${base}Network error: ${error.toString()}';
  }

  if (error is TypeError ||
      message.contains("is not a subtype of type 'string'") ||
      (message.contains('null') && message.contains('string'))) {
    return '${base}Provider returned an unexpected response. '
        'Check that the URL, protocol, and model match the API '
        '(Claude-compatible endpoints must return Anthropic-shaped messages).';
  }

  if (error is ArgumentError) {
    return '$base${error.message}';
  }

  return '$base${error.toString()}';
}

List<ChatMessage> _sanitizeMessagesForPrompt(List<ChatMessage> messages) {
  return messages.map((message) {
    if (message is AIChatMessage) {
      if (message.reasoningContent.isNotEmpty) {
        return AIChatMessage(
          content: message.content,
          toolCalls: message.toolCalls,
        );
      }
      final plainText = reasoningContentToPlainText(message.content);
      if (plainText == message.content) {
        return message;
      }
      return AIChatMessage(
        content: plainText,
        toolCalls: message.toolCalls,
      );
    }
    return message;
  }).toList(growable: false);
}

String? _latestUserMessage(List<ChatMessage> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (message is HumanChatMessage) {
      return message.contentAsString;
    }
  }
  return null;
}
