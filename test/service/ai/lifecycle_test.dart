import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/service/ai/chat_session.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';
import 'package:anx_reader/service/ai/langchain_runner.dart';
import 'package:anx_reader/service/ai/openai_codec.dart';
import 'package:anx_reader/service/ai/openai_http_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:langchain/langchain.dart';

import 'openai_http_test.dart' as fixture;

void main() {
  test('Responses 结束帧省略 output 时保留已完成原生项与工具调用', () async {
    final session = AiChatSession();
    final items = [
      {
        'type': 'reasoning',
        'id': 'rs_complete',
        'summary': [],
        'encrypted_content': 'complete-encrypted-state',
      },
      {
        'type': 'function_call',
        'id': 'fc_1',
        'call_id': 'call_1',
        'name': 'lookup',
        'arguments': '{"n":1}',
      },
    ];
    final m = fixture.model(true, session, MockClient((_) async {
      return fixture.sse([
        {
          'type': 'response.output_item.added',
          'output_index': 0,
          'item': {'type': 'reasoning', 'encrypted_content': 'partial'},
        },
        for (var i = 0; i < items.length; i++)
          {
            'type': 'response.output_item.done',
            'output_index': i,
            'item': items[i],
          },
        fixture.completed([]),
      ]);
    }));
    final result = await m.invoke(fixture.prompt);
    expect(result.output.toolCalls.single.id, 'call_1');
    expect(session.nativeItems.skip(1), items);
    m.close();
  });

  test('Responses 历史恢复回传加密推理，重新生成使用用户消息之前的检查点', () async {
    final original = AiChatSession()..checkpoint(0);
    final first = fixture.model(
        true,
        original,
        MockClient((_) async => fixture.sse([
              fixture.completed([
                {
                  'type': 'reasoning',
                  'id': 'rs',
                  'summary': [
                    {'type': 'summary_text', 'text': '摘要'}
                  ],
                  'encrypted_content': 'opaque'
                },
                fixture.answer('第一轮'),
              ]),
            ])));
    await first.invoke(fixture.prompt);
    original.checkpoint(2);
    final restored =
        AiChatSession.fromJson(jsonDecode(jsonEncode(original.toJson())));
    final followup = fixture.model(true, restored, MockClient((request) async {
      final input = jsonDecode(request.body)['input'] as List;
      expect(input.length, 4);
      expect(input[1]['encrypted_content'], 'opaque');
      expect(input.last['content'], '继续');
      expect(input.where((i) => i['content'] == '你好').length, 1);
      return fixture.success(true);
    }));
    await followup.invoke(PromptValue.chat([
      ChatMessage.humanText('你好'),
      ChatMessage.ai('展示文字'),
      ChatMessage.humanText('继续'),
    ]));
    restored.rewind(0);
    final regenerated =
        fixture.model(true, restored, MockClient((request) async {
      expect(jsonDecode(request.body)['input'], [
        {'role': 'user', 'content': '你好'}
      ]);
      return fixture.success(true);
    }));
    await regenerated.invoke(fixture.prompt);
  });

  test('回退失败不修改会话，重复拒绝同一参数不无限重试', () async {
    for (final responses in [false, true]) {
      final session = AiChatSession()..priority = true;
      var requests = 0;
      final m = fixture.model(responses, session, MockClient((_) async {
        requests++;
        return fixture.reject('service_tier');
      }));
      await expectLater(
          m.invoke(fixture.prompt), throwsA(isA<OpenAiRequestError>()));
      expect(requests, 2);
      expect(session.priority, true);
    }
  });

  test('已收到函数调用参数后，不再做参数回退', () async {
    final session = AiChatSession()..priority = true;
    var requests = 0;
    final m = fixture.model(true, session, MockClient((_) async {
      requests++;
      return fixture.sse([
        {'type': 'response.function_call_arguments.delta', 'delta': '{'},
        {
          'type': 'error',
          'code': 'unsupported_parameter',
          'param': 'service_tier',
          'message': 'unsupported'
        },
      ]);
    }));
    await expectLater(
        m.invoke(fixture.prompt), throwsA(isA<OpenAiRequestError>()));
    expect(requests, 1);
  });

  test('普通 400、上下文超限、错误无诊断不回退', () {
    for (final error in [
      {'message': 'Bad request'},
      {
        'code': 'context_length_exceeded',
        'message': 'reasoning_effort exceeds available context'
      },
      {'code': 'invalid_api_key', 'message': 'Invalid credentials'},
    ]) {
      expect(OpenAiRequestError(400, error).rejectedOptions, isEmpty);
    }
    expect(
        OpenAiRequestError(
                400, {'code': 'invalid_value', 'param': 'reasoning.effort'})
            .rejectedOptions,
        {'reasoning'});
  });

  for (final responses in [true, false]) {
    test('缺少终止事件会失败，responses=$responses', () async {
      final m = fixture.model(
          responses,
          AiChatSession(),
          MockClient((_) async => fixture.sse([
                if (responses)
                  {'type': 'response.output_text.delta', 'delta': '未完'}
                else
                  {
                    'choices': [
                      {
                        'delta': {'content': '未完'}
                      }
                    ]
                  },
              ])));
      await expectLater(m.invoke(fixture.prompt), throwsStateError);
    });
  }

  test('Responses incomplete 不提交原生状态', () async {
    final session = AiChatSession();
    final m = fixture.model(
        true,
        session,
        MockClient((_) async => fixture.sse([
              {
                'type': 'response.incomplete',
                'response': {
                  'incomplete_details': {'reason': 'max_output_tokens'}
                }
              },
            ])));
    await expectLater(m.invoke(fixture.prompt), throwsStateError);
    expect(session.nativeItems, isEmpty);
  });

  test('本地 HTTP/SSE 分片传输，停止会断开请求并结束循环', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestStarted = Completer<void>();
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response.bufferOutput = false;
      final bytes = utf8.encode(
          'data: {"type":"response.output_text.delta","delta":"中文"}\n\n');
      for (final byte in bytes) {
        request.response.add([byte]);
        await request.response.flush();
      }
      requestStarted.complete();
      // 留住响应，验证取消不必等待服务器发来下一帧。
    });
    final session = AiChatSession()..status = AiRunStatus.running;
    final m = OpenAiHttpModel(
        config: LangchainAiConfig(
            identifier: 'test',
            model: 'test',
            apiKey: 'test',
            baseUrl: 'http://127.0.0.1:${server.port}/v1'),
        responses: true,
        session: session);
    final runner = CancelableLangchainRunner();
    addTearDown(runner.cancel);
    final emitted = Completer<void>();
    final finished = Completer<void>();
    runner
        .streamAgent(
            model: m, tools: [], history: [], input: '你好', session: session)
        .listen((text) {
      if (!emitted.isCompleted) emitted.complete();
    }, onDone: () {
      if (!finished.isCompleted) finished.complete();
    }, onError: (Object error, StackTrace stack) {
      if (!finished.isCompleted) finished.completeError(error, stack);
    });
    await requestStarted.future.timeout(const Duration(seconds: 3),
        onTimeout: () => throw StateError('请求未到达本地服务器'));
    await emitted.future.timeout(const Duration(seconds: 3),
        onTimeout: () => throw StateError('没有收到流式数据'));
    runner.cancel();
    await finished.future.timeout(const Duration(seconds: 2));
    expect(session.status, AiRunStatus.cancelled);
    expect(requests, 1);
    await server.close(force: true);
  });

  test('工具执行期间停止，不执行剩余工具或下一轮请求', () async {
    final started = Completer<void>();
    final gate = Completer<String>();
    var executions = 0;
    var requests = 0;
    final tool = Tool.fromFunction<Map<String, dynamic>, String>(
        name: 'slow',
        description: '慢工具',
        inputJsonSchema: const {'type': 'object', 'properties': {}},
        getInputFromJson: (json) => json,
        func: (_) {
          executions++;
          started.complete();
          return gate.future;
        });
    final session = AiChatSession()..status = AiRunStatus.running;
    final m = fixture.model(true, session, MockClient((_) async {
      requests++;
      return fixture.sse([
        fixture.completed([
          for (final id in ['a', 'b'])
            {
              'type': 'function_call',
              'call_id': id,
              'name': 'slow',
              'arguments': '{}'
            },
        ])
      ]);
    }));
    final runner = CancelableLangchainRunner();
    final finished = runner
        .streamAgent(
            model: m, tools: [tool], history: [], input: '运行', session: session)
        .toList();
    await started.future;
    runner.cancel();
    await finished.timeout(const Duration(seconds: 2));
    gate.complete('完成');
    await Future<void>.delayed(Duration.zero);
    expect(executions, 1);
    expect(requests, 1);
  });
}
