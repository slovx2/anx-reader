import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/ai_reasoning_effort.dart';
import 'package:anx_reader/enums/hint_key.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/providers/ai_chat.dart';
import 'package:anx_reader/service/ai/ai_history.dart';
import 'package:anx_reader/service/ai/chat_session.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:anx_reader/widgets/ai/ai_chat_stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PendingChat extends AiChat {
  @override
  Future<void> send(String message) async {
    session.status = AiRunStatus.running;
    state = AsyncData(
        [ChatMessage.humanText(message), ChatMessage.ai('流式回答')]);
    await session.whenCancelled;
    ref.notifyListeners();
  }
}

Widget _chatApp(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          navigatorKey: navigatorKey,
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: const Scaffold(body: AiChatStream())),
    );

Future<void> _initPendingProvider() async {
  SharedPreferences.setMockInitialValues({});
  await Prefs().initPrefs();
  Prefs().saveAiProviders([
    const AiProvider(
        id: 'test',
        title: 'Test',
        url: 'http://localhost/v1',
        protocol: AiProtocol.openaiResponses,
        model: 'model')
  ]);
  Prefs().selectedAiService = 'test';
  Prefs().setShowHint(HintKey.aiDataSharingConsent, false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final protocol in AiProtocol.values) {
    testWidgets('聊天菜单按协议显示档位：${protocol.name}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs().initPrefs();
      final provider = AiProvider(
          id: 'test',
          title: 'Test',
          url: 'http://localhost/v1',
          protocol: protocol,
          model: 'model',
          reasoningEffort: AiReasoningEffort.medium);
      Prefs().saveAiProviders([provider]);
      Prefs().selectedAiService = provider.id;
      Prefs().setShowHint(HintKey.aiDataSharingConsent, false);
      final container = ProviderContainer();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: const Scaffold(body: AiChatStream())),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      expect(find.text('model'), findsWidgets);
      expect(
          find.text('服务档位'), protocol.isOpenAi ? findsOneWidget : findsNothing);
      if (protocol.isOpenAi) {
        await tester.tap(find.text('高'));
        await tester.pumpAndSettle();
        expect(container.read(aiChatProvider.notifier).session.reasoning,
            AiReasoningEffort.high);
        expect(provider.reasoningEffort, AiReasoningEffort.medium);
        await tester.tap(find.byIcon(Icons.tune));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('优先'));
        await tester.tap(find.text('优先'));
        await tester.pumpAndSettle();
        expect(container.read(aiChatProvider.notifier).session.priority, true);
        final saved = AiChatHistoryEntry(
            id: 'saved',
            serviceId: provider.id,
            model: provider.model,
            createdAt: 1,
            updatedAt: 1,
            messages: [],
            completed: true,
            sessionData:
                container.read(aiChatProvider.notifier).session.toJson());
        container.read(aiChatProvider.notifier).clear();
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.tune));
        await tester.pumpAndSettle();
        expect(container.read(aiChatProvider.notifier).session.priority, false);
        expect(container.read(aiChatProvider.notifier).session.reasoning,
            AiReasoningEffort.medium);
        Navigator.of(tester.element(find.text('服务档位'))).pop();
        await tester.pumpAndSettle();
        container.read(aiChatProvider.notifier).loadHistoryEntry(saved);
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.tune));
        await tester.pumpAndSettle();
        expect(container.read(aiChatProvider.notifier).session.priority, true);
        expect(container.read(aiChatProvider.notifier).session.reasoning,
            AiReasoningEffort.high);
      }
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
  }
  testWidgets('生成时锁定菜单，停止完成后恢复操作', (tester) async {
    await _initPendingProvider();
    final container = ProviderContainer(
        overrides: [aiChatProvider.overrideWith(PendingChat.new)]);
    await tester.pumpWidget(_chatApp(container));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '你好');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    final tune = find.widgetWithIcon(IconButton, Icons.tune);
    expect(tester.widget<IconButton>(tune).onPressed, isNull);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pumpAndSettle();
    expect(container.read(aiChatProvider.notifier).session.status,
        AiRunStatus.cancelled);
    expect(tester.widget<IconButton>(tune).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
  testWidgets('关闭聊天界面不中断运行，重新打开后接上并可停止', (tester) async {
    await _initPendingProvider();
    final container = ProviderContainer(
        overrides: [aiChatProvider.overrideWith(PendingChat.new)]);
    await tester.pumpWidget(_chatApp(container));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '你好');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    final notifier = container.read(aiChatProvider.notifier);
    expect(notifier.session.status, AiRunStatus.running);
    expect(notifier.isRunning, isTrue);

    await tester.pumpWidget(_chatApp(container));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.stop), findsOneWidget);
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pumpAndSettle();
    expect(notifier.session.status, AiRunStatus.cancelled);
    expect(find.byIcon(Icons.send), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
}
