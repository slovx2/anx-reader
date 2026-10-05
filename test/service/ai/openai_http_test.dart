import 'dart:async';
import 'dart:convert';

import 'package:anx_reader/enums/ai_reasoning_effort.dart';
import 'package:anx_reader/service/ai/chat_session.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';
import 'package:anx_reader/service/ai/langchain_runner.dart';
import 'package:anx_reader/service/ai/openai_codec.dart';
import 'package:anx_reader/service/ai/openai_http_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:langchain/langchain.dart';

OpenAiHttpModel model(
        bool responses, AiChatSession session, http.Client client) =>
    OpenAiHttpModel(
        config: LangchainAiConfig(
            identifier: 'test',
            model: 'model',
            apiKey: 'test-key',
            baseUrl: 'http://localhost/v1'),
        responses: responses,
        session: session,
        client: client);

final prompt = PromptValue.chat([ChatMessage.humanText('你好')]);
Map<String, dynamic> completed(List<Map<String, dynamic>> output) => {
      'type': 'response.completed',
      'response': {'status': 'completed', 'output': output},
    };
Map<String, dynamic> answer(String text) => {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': text}
      ],
    };
http.Response sse(List<Map<String, dynamic>> events) => http.Response.bytes(
      utf8.encode(
          '${events.map((e) => 'data: ${jsonEncode(e)}\r\n\r\n').join()}data: [DONE]\r\n\r\n'),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
http.Response success(bool responses) => sse(responses
    ? [
        completed([answer('完成')])
      ]
    : [
        {
          'choices': [
            {
              'delta': {'content': '完成'},
              'finish_reason': 'stop'
            }
          ]
        },
      ]);
http.Response reject(String param, {int status = 400}) => http.Response(
    jsonEncode({
      'error': {
        'code': 'unsupported_parameter',
        'param': param,
        'message': '$param is not supported'
      },
    }),
    status);

void main() {
  test('SSE 任意字节拆包、中文、多行和最后一帧', () async {
    final bytes = utf8.encode(
        ': heartbeat\r\ndata: {"text":\r\ndata: "中文😀"}\r\n\r\ndata: {"last":true}');
    final decoded =
        await decodeOpenAiSse(Stream.fromIterable(bytes.map((b) => [b])))
            .toList();
    expect(decoded, [
      {'text': '中文😀'},
      {'last': true}
    ]);
    expect(openAiBaseUrl('https://example.com/v1/responses'),
        'https://example.com/v1');
    expect(openAiBaseUrl('https://example.com/v1/chat/completions/'),
        'https://example.com/v1');
  });

  for (final responses in [false, true]) {
    group(responses ? 'Responses' : 'Chat Completions', () {
      test('默认省略档位，低中高和优先正确映射', () async {
        for (final effort in AiReasoningEffort.values) {
          final session = AiChatSession()
            ..reasoning = effort
            ..priority = effort != AiReasoningEffort.auto;
          final client = MockClient((request) async {
            final body = jsonDecode(request.body) as Map;
            expect(request.url.path,
                responses ? '/v1/responses' : '/v1/chat/completions');
            expect(body['service_tier'], session.priority ? 'priority' : null);
            expect(
                responses
                    ? ((body['reasoning'] as Map?)?['effort'])
                    : body['reasoning_effort'],
                effort == AiReasoningEffort.auto ? null : effort.code);
            if (responses) {
              expect(body['store'], false);
              expect(body['include'], contains('reasoning.encrypted_content'));
            }
            return success(responses);
          });
          final m = model(responses, session, client);
          expect((await m.invoke(prompt)).output.content, '完成');
          m.close();
        }
      });

      test('双参数分别拒绝，最多三次请求且不改变其他会话', () async {
        final session = AiChatSession()
          ..reasoning = AiReasoningEffort.high
          ..priority = true;
        final other = AiChatSession()
          ..reasoning = AiReasoningEffort.low
          ..priority = true;
        var count = 0;
        final client = MockClient((request) async {
          count++;
          final body = jsonDecode(request.body) as Map;
          if (count == 1) return reject('service_tier');
          expect(body.containsKey('service_tier'), false);
          if (count == 2) {
            return reject(responses ? 'reasoning.effort' : 'reasoning_effort');
          }
          expect(body.containsKey(responses ? 'reasoning' : 'reasoning_effort'),
              false);
          return success(responses);
        });
        await model(responses, session, client).invoke(prompt);
        expect(count, 3);
        expect(session.priority, false);
        expect(session.reasoning, AiReasoningEffort.auto);
        expect(other.priority, true);
        expect(other.reasoning, AiReasoningEffort.low);
      });

      for (final status in [401, 429, 500]) {
        test('HTTP $status 不触发参数回退', () async {
          var count = 0;
          final session = AiChatSession()..priority = true;
          final m = model(responses, session, MockClient((_) async {
            count++;
            return reject('service_tier', status: status);
          }));
          await expectLater(
              m.invoke(prompt), throwsA(isA<OpenAiRequestError>()));
          expect(count, 1);
          expect(session.priority, true);
        });
      }

      test('已经输出后不回退，不吞终止错误', () async {
        var count = 0;
        final session = AiChatSession()..priority = true;
        final m = model(responses, session, MockClient((_) async {
          count++;
          return sse([
            if (responses)
              {'type': 'response.output_text.delta', 'delta': '部分'}
            else
              {
                'choices': [
                  {
                    'delta': {'content': '部分'}
                  }
                ]
              },
            {
              'error': {
                'code': 'unsupported_parameter',
                'param': 'service_tier',
                'message': 'unsupported service_tier'
              }
            },
          ]);
        }));
        await expectLater(
            m.stream(prompt),
            emitsInOrder([
              isA<ChatResult>(),
              emitsError(isA<OpenAiRequestError>()),
              emitsDone,
            ]));
        expect(count, 1);
      });

      test('多个工具只执行一次，结果编码和 strict:false', () async {
        var requests = 0;
        final executed = <int>[];
        final session = AiChatSession()
          ..status = AiRunStatus.running
          ..priority = true;
        final tool = Tool.fromFunction<Map<String, dynamic>, String>(
          name: 'lookup',
          description: '查询',
          inputJsonSchema: const {
            'type': 'object',
            'properties': {
              'n': {'type': 'integer'}
            },
          },
          getInputFromJson: (json) => json,
          func: (input) {
            executed.add(input['n'] as int);
            return '结果${input['n']}';
          },
        );
        final m = model(responses, session, MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map;
          final spec = (body['tools'] as List).first as Map;
          expect(
              responses ? spec['strict'] : spec['function']['strict'], false);
          if (requests == 1) {
            return sse(responses
                ? [
                    completed([
                      {
                        'type': 'reasoning',
                        'id': 'rs_1',
                        'summary': [],
                        'encrypted_content': 'encrypted'
                      },
                      for (var n = 1; n <= 2; n++)
                        {
                          'type': 'function_call',
                          'id': 'fc_$n',
                          'call_id': 'call_$n',
                          'name': 'lookup',
                          'arguments': '{"n":$n}'
                        },
                    ])
                  ]
                : [
                    {
                      'choices': [
                        {
                          'delta': {
                            'tool_calls': [
                              for (var n = 1; n <= 2; n++)
                                {
                                  'index': n - 1,
                                  'id': 'call_$n',
                                  'type': 'function',
                                  'function': {
                                    'name': 'lookup',
                                    'arguments': '{"n":'
                                  }
                                },
                            ]
                          }
                        }
                      ]
                    },
                    {
                      'choices': [
                        {
                          'delta': {
                            'tool_calls': [
                              for (var n = 1; n <= 2; n++)
                                {
                                  'index': n - 1,
                                  'function': {'arguments': '$n}'}
                                },
                            ]
                          },
                          'finish_reason': 'tool_calls'
                        }
                      ]
                    },
                  ]);
          }
          final items = body[responses ? 'input' : 'messages'] as List;
          final outputs = items
              .where((i) => responses
                  ? i['type'] == 'function_call_output'
                  : i['role'] == 'tool')
              .toList();
          expect(outputs.length, 2);
          expect(outputs.map((i) => i[responses ? 'call_id' : 'tool_call_id']),
              ['call_1', 'call_2']);
          if (responses) {
            expect(
                items
                    .where((i) => i['type'] == 'reasoning')
                    .single['encrypted_content'],
                'encrypted');
          }
          // 工具执行后服务参数被拒绝，重试只重发模型请求。
          if (requests == 2) return reject('service_tier');
          return success(responses);
        }));
        final output = await CancelableLangchainRunner()
            .streamAgent(
                model: m,
                tools: [tool],
                history: [],
                input: '查两条',
                session: session)
            .toList();
        expect(output, isNotEmpty);
        expect(executed, [1, 2]);
        expect(requests, 3);
      });
    });
  }
}
