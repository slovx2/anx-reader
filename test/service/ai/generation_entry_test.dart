import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/service/ai/ai_model_service.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';
import 'package:anx_reader/service/ai/langchain_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_anthropic/langchain_anthropic.dart';
import 'package:langchain_google/langchain_google.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'openai_http_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 本文件只连接本机 mock server，恢复真实 socket 以验证公开生成入口。
  HttpOverrides.global = null;
  for (final protocol in [AiProtocol.openai, AiProtocol.openaiResponses]) {
    test('非聊天文本流和模型获取：${protocol.code}', () async {
      // 普通 test 使用实际 loopback HTTP，不使用 widget 测试的网络替身。
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final responses = protocol == AiProtocol.openaiResponses;
      final suffix = responses ? 'responses' : 'chat/completions';
      final endpoint = 'http://127.0.0.1:${server.port}/v1/$suffix';
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        if (request.uri.path == '/v1/models') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'data': [
              {'id': 'model-b'},
              {'id': 'model-a'}
            ]
          }));
        } else {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(body.containsKey('tools'), false);
          if (responses) expect(body['store'], false);
          request.response.headers.contentType =
              ContentType('text', 'event-stream');
          request.response.add(fixture.success(responses).bodyBytes);
        }
        await request.response.close();
      });
      SharedPreferences.setMockInitialValues({});
      await Prefs().initPrefs();
      final provider = AiProvider(
          id: 'entry',
          title: 'Entry',
          url: endpoint,
          protocol: protocol,
          model: 'model-a',
          apiKeys: [const AiApiKey(id: 'key', key: 'test')]);
      Prefs().saveAiProviders([provider]);
      Prefs().selectedAiService = provider.id;
      final generated =
          await aiGenerateStream([ChatMessage.humanText('测试')]).toList();
      expect(generated.last, '完成');
      expect(await fetchAiModels(url: endpoint, apiKey: 'test'),
          ['model-a', 'model-b']);
      expect(paths, ['/v1/$suffix', '/v1/models']);
      final reloaded = AiProvider.fromJson(
          Prefs().getAiProviders().single as Map<String, dynamic>);
      expect(reloaded.protocol, protocol);
    });
  }
  test('Claude 和 Gemini 继续使用原适配器', () {
    final registry = LangchainAiRegistry(null);
    final config =
        LangchainAiConfig(identifier: 'test', model: 'model', apiKey: 'test');
    final claude = registry.resolveByProtocol(AiProtocol.claude, config).model;
    final gemini = registry.resolveByProtocol(AiProtocol.gemini, config).model;
    expect(claude, isA<ChatAnthropic>());
    expect(gemini, isA<ChatGoogleGenerativeAI>());
    claude.close();
    gemini.close();
  });
}
