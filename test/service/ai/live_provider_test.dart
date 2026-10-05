import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/enums/ai_reasoning_effort.dart';
import 'package:anx_reader/service/ai/chat_session.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';
import 'package:anx_reader/service/ai/langchain_runner.dart';
import 'package:anx_reader/service/ai/openai_http_model.dart';
import 'package:anx_reader/utils/ai_reasoning_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain/langchain.dart';

// 显式设置私密配置文件才联网，普通测试不会消费真实端点。
void main() {
  final path = Platform.environment['ANX_LIVE_CONFIG'];
  for (final responses in [false, true]) {
    test('${responses ? 'Responses' : 'Chat Completions'} 真实端点工具与续聊', () async {
      HttpOverrides.global = null;
      final raw = jsonDecode(File(path!).readAsStringSync()) as Map;
      final config = LangchainAiConfig(
        identifier: 'live-validation',
        model: raw['model'] as String,
        apiKey: raw['apiKey'] as String,
        baseUrl: raw['url'] as String,
      );
      final session = AiChatSession()
        ..reasoning = AiReasoningEffort.low
        ..priority = true
        ..status = AiRunStatus.running;
      final executed = <int>[];
      final tool = Tool.fromFunction<Map<String, dynamic>, String>(
        name: 'lookup_fixture',
        description: '读取验收用合成记录，序号仅支持 1 和 2。',
        inputJsonSchema: const {
          'type': 'object',
          'properties': {
            'n': {'type': 'integer'}
          },
          'required': ['n'],
        },
        getInputFromJson: (json) => json,
        func: (input) {
          final n = input['n'] as int;
          executed.add(n);
          return n == 1 ? '蓝鹭-731' : '银杏-482';
        },
      );
      session.checkpoint(0);
      final output = await CancelableLangchainRunner()
          .streamAgent(
            model: OpenAiHttpModel(
                config: config, responses: responses, session: session),
            tools: [tool],
            history: [],
            input: '分别调用 lookup_fixture 读取序号1和2，各调用一次。'
                '最后只原样列出两条记录。',
            session: session,
          )
          .toList();
      final display = reasoningContentToPlainText(output.last);
      expect(executed, unorderedEquals([1, 2]), reason: display);
      expect(display, contains('蓝鹭-731'));
      expect(display, contains('银杏-482'));
      session.status = AiRunStatus.completed;
      final restored = AiChatSession.fromJson(
          jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>);
      if (responses) {
        expect(restored.nativeItems, isNotEmpty);
        expect(
            restored.nativeItems
                .where((item) => item['type'] == 'function_call_output'),
            hasLength(2));
      }
      final next = OpenAiHttpModel(
          config: config, responses: responses, session: restored);
      try {
        final answer = await next.invoke(PromptValue.chat([
          if (!responses) ...[
            ChatMessage.humanText('记住这两条记录'),
            ChatMessage.ai('蓝鹭-731，银杏-482'),
          ],
          ChatMessage.humanText('刚才序号2的记录是什么？只原样输出记录。'),
        ]));
        expect(answer.output.content, contains('银杏-482'));
      } finally {
        next.close();
      }
      if (responses) {
        final encrypted = session.nativeItems
            .where((item) => item['encrypted_content'] != null)
            .length;
        // 仅输出计数，不能把原生加密内容或密钥写入日志。
        stdout.writeln(
            'Responses 原生项 ${session.nativeItems.length}，加密推理项 $encrypted');
        restored.rewind(0);
        expect(restored.nativeItems, isEmpty);
        final regenerated = OpenAiHttpModel(
            config: config, responses: responses, session: restored);
        try {
          final answer = await regenerated.invoke(PromptValue.chat([
            ChatMessage.humanText('只输出：重新生成成功'),
          ]));
          expect(answer.output.content, contains('重新生成成功'));
          expect(restored.nativeItems.any((i) => i['type'] == 'function_call'),
              false);
        } finally {
          regenerated.close();
        }
      }
      stdout.writeln('有效档位：priority=${session.priority}, '
          'reasoning=${session.reasoning.code}；工具执行 ${executed.length} 次');
    }, skip: path == null, timeout: const Timeout(Duration(minutes: 3)));

    test('${responses ? 'Responses' : 'Chat Completions'} 真实端点档位与停止', () async {
      HttpOverrides.global = null;
      final raw = jsonDecode(File(path!).readAsStringSync()) as Map;
      final config = LangchainAiConfig(
          identifier: 'live-validation',
          model: raw['model'] as String,
          apiKey: raw['apiKey'] as String,
          baseUrl: raw['url'] as String);
      for (final effort in [
        AiReasoningEffort.auto,
        AiReasoningEffort.medium,
        AiReasoningEffort.high
      ]) {
        final session = AiChatSession()..reasoning = effort;
        final model = OpenAiHttpModel(
            config: config, responses: responses, session: session);
        try {
          final answer = await model.invoke(PromptValue.chat([
            ChatMessage.humanText('只输出：档位验收成功'),
          ]));
          expect(answer.output.content, contains('档位验收成功'));
          stdout.writeln('请求 ${effort.code}，成功后 ${session.reasoning.code}');
        } finally {
          model.close();
        }
      }
      final session = AiChatSession()..status = AiRunStatus.running;
      final runner = CancelableLangchainRunner();
      addTearDown(runner.cancel);
      final first = Completer<void>();
      final done = Completer<void>();
      var events = 0;
      runner
          .streamAgent(
        model: OpenAiHttpModel(
            config: config, responses: responses, session: session),
        tools: [],
        history: [],
        session: session,
        input: '从1数到5000，每行一个数字，不要省略。',
      )
          .listen((_) {
        events++;
        if (!first.isCompleted) first.complete();
      }, onDone: done.complete, onError: done.completeError);
      await first.future.timeout(const Duration(seconds: 60));
      runner.cancel();
      final before = events;
      await done.future.timeout(const Duration(seconds: 3));
      expect(session.status, AiRunStatus.cancelled);
      expect(events, before);
      stdout.writeln('收到流式数据后取消，3秒内完成，未继续输出');
    }, skip: path == null, timeout: const Timeout(Duration(minutes: 4)));
  }
}
