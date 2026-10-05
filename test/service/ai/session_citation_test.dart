import 'dart:convert';

import 'package:anx_reader/enums/ai_reasoning_effort.dart';
import 'package:anx_reader/service/ai/ai_history.dart';
import 'package:anx_reader/service/ai/chat_session.dart';
import 'package:anx_reader/service/ai/citations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('历史快照、档位、原生上下文、重新生成和服务切换隔离', () {
    final session = AiChatSession()
      ..configure('provider|responses|model', AiReasoningEffort.medium);
    session.checkpoint(0);
    session.nativeItems = [
      {'type': 'reasoning', 'encrypted_content': 'secret'}
    ];
    session.checkpoint(2);
    session.priority = true;
    session.status = AiRunStatus.completed;
    final saved = session.toJson();
    session.nativeItems.clear();
    final restored = AiChatSession.fromJson(jsonDecode(jsonEncode(saved)));
    expect(restored.nativeItems.single['encrypted_content'], 'secret');
    expect(restored.priority, true);
    expect(restored.reasoning, AiReasoningEffort.medium);
    restored.rewind(0);
    expect(restored.nativeItems, isEmpty);
    expect(restored.checkpoints.containsKey(2), false);
    restored.configure(
        'provider|responses|another-model', AiReasoningEffort.low);
    expect(restored.priority, false);
    expect(restored.reasoning, AiReasoningEffort.low);
    expect(restored.checkpoints, isEmpty);
  });

  test('旧历史不补造状态，崩溃留下的运行状态恢复为取消', () {
    final old = AiChatHistoryEntry.fromJson({'id': 'old', 'messages': []});
    final session = AiChatSession.fromJson(old.sessionData);
    expect(session.nativeItems, isEmpty);
    expect(session.citations, isEmpty);
    expect(session.reasoning, AiReasoningEffort.auto);
    expect(session.priority, false);
    expect(AiChatSession.fromJson({'status': 'running'}).status,
        AiRunStatus.cancelled);
  });

  test('搜索、笔记精确引用固定书籍身份和指纹，持久化后仍可解析', () {
    final session = AiChatSession();
    final registry = AiCitationRegistry(session);
    final search = jsonDecode(registry.enrich(
        'book_content_search',
        jsonEncode({
          'status': 'ok',
          'data': {
            'bookId': 42,
            'md5': 'fingerprint',
            'results': [
              {
                'chapterTitle': '第一章',
                'matches': [
                  {
                    'cfi': 'epubcfi(/6/2!/4/1:5)',
                    'pre': '前',
                    'match': '原文',
                    'post': '后'
                  }
                ]
              },
            ]
          },
        }),
        bookId: 99));
    final link =
        search['data']['results'][0]['matches'][0]['citationUrl'] as String;
    expect(registry.resolve(link)!['bookId'], 42);
    expect(registry.resolve(link)!['md5'], 'fingerprint');
    expect(registry.resolve(link)!['quote'], '前原文后');
    registry.enrich(
        'notes_search',
        jsonEncode({
          'status': 'ok',
          'data': {
            'results': [
              {
                'bookId': 43,
                'md5': 'another',
                'chapter': '笔记章节',
                'content': '摘录',
                'cfi': 'epubcfi(/2/1:1)'
              },
            ]
          }
        }));
    final entry = AiChatHistoryEntry(
        id: 'id',
        serviceId: 'test',
        model: 'model',
        createdAt: 1,
        updatedAt: 2,
        messages: [],
        completed: true,
        sessionData: session.toJson());
    final restored =
        AiChatHistoryEntry.fromJson(jsonDecode(jsonEncode(entry.toJson())));
    final restoredRegistry =
        AiCitationRegistry(AiChatSession.fromJson(restored.sessionData));
    expect(restoredRegistry.resolve(link), registry.resolve(link));
    expect(restoredRegistry.session.citations.values.last['bookId'], 43);
    expect(restoredRegistry.resolve('anx://citation/unknown'), isNull);
    expect(
        restoredRegistry
            .resolve('https://citation/${session.citations.keys.first}'),
        isNull);
    expect(AiCitationRegistry(AiChatSession()).resolve(link), isNull);
  });

  test('目录递归和章节引用，特殊字符完整保留', () {
    final registry = AiCitationRegistry(AiChatSession());
    const href = "Text/第'一章.xhtml#段落\\\"\n";
    final toc = jsonDecode(registry.enrich(
        'current_book_toc',
        jsonEncode({
          'status': 'ok',
          'data': {
            'toc': [
              {
                'title': '章',
                'href': href,
                'children': [
                  {
                    'title': '节',
                    'href': 'chapter.xhtml#section',
                    'children': []
                  },
                ]
              }
            ]
          },
        }),
        bookId: 9,
        md5: 'hash'));
    final item = toc['data']['toc'][0];
    expect(item['citation'], startsWith('[查看章节](anx://citation/'));
    expect(registry.resolve(item['citationUrl'])!['href'], href);
    registry.enrich(
        'chapter_content_by_href',
        jsonEncode({
          'status': 'ok',
          'data': {'content': '正文'}
        }),
        bookId: 9,
        href: href,
        chapter: '章',
        md5: 'hash');
    expect(registry.session.citations.length, 3);
    expect(registry.session.citations.values.last['quote'], '正文');
    expect(registry.enrich('calculator', '42'), '42');
  });
}
