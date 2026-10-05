import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'chat_session.dart';

/// 引用链接只能由工具结果创建；模型负责选用，不负责构造阅读器坐标。
class AiCitationRegistry {
  AiCitationRegistry(this.session);
  final AiChatSession session;

  String register(
      {required int bookId,
      required String chapter,
      String? cfi,
      String? href,
      String? md5,
      String quote = ''}) {
    final id = const Uuid().v4();
    session.citations[id] = {
      'id': id,
      'bookId': bookId,
      'chapter': chapter,
      if (cfi?.isNotEmpty == true) 'cfi': cfi,
      if (href?.isNotEmpty == true) 'href': href,
      if (md5?.isNotEmpty == true) 'md5': md5,
      'quote': quote,
    };
    return 'anx://citation/$id';
  }

  Map<String, dynamic>? resolve(String href) {
    final uri = Uri.tryParse(href);
    if (uri?.scheme != 'anx' ||
        uri?.host != 'citation' ||
        uri!.pathSegments.length != 1) {
      return null;
    }
    return session.citations[uri.pathSegments.single];
  }

  String enrich(String tool, String output,
      {int? bookId, String? md5, String chapter = '', String? href}) {
    if (!const {
      'book_content_search',
      'notes_search',
      'current_book_toc',
      'current_chapter_content',
      'chapter_content_by_href'
    }.contains(tool)) {
      return output;
    }
    final root = jsonDecode(output);
    if (root is! Map || root['status'] != 'ok') return output;
    final data = root['data'];
    void cite(Map item,
        {required int book,
        String? cfi,
        String? chapterHref,
        String title = '',
        String quote = '',
        String? fingerprint}) {
      if ((cfi == null || cfi.isEmpty) &&
          (chapterHref == null || chapterHref.isEmpty)) {
        return;
      }
      final url = register(
          bookId: book,
          chapter: title,
          cfi: cfi,
          href: chapterHref,
          md5: fingerprint,
          quote: quote);
      item['citationUrl'] = url;
      final label = cfi?.isNotEmpty == true ? '查看原文' : '查看章节';
      item['citation'] = '[$label]($url)';
    }

    if (tool == 'book_content_search' && data is Map && data['bookId'] is int) {
      for (final result in data['results'] as List? ?? []) {
        for (final match in result['matches'] as List? ?? []) {
          cite(match as Map,
              book: data['bookId'] as int,
              fingerprint: data['md5'] as String?,
              cfi: match['cfi'] as String?,
              title: result['chapterTitle'] as String? ?? '',
              quote:
                  '${match['pre'] ?? ''}${match['match'] ?? ''}${match['post'] ?? ''}');
        }
      }
    } else if (tool == 'notes_search') {
      final notes = data is List
          ? data
          : data is Map
              ? data['results']
              : null;
      for (final note in notes is List ? notes : []) {
        if (note['bookId'] is int) {
          cite(note as Map,
              book: note['bookId'] as int,
              fingerprint: note['md5'] as String?,
              cfi: note['cfi'] as String?,
              title: note['chapter'] as String? ?? '',
              quote: '${note['content'] ?? ''}');
        }
      }
    } else if (bookId != null && data is Map) {
      if (tool == 'current_book_toc') {
        void walk(List items) {
          for (final item in items) {
            cite(item as Map,
                book: bookId,
                chapterHref: item['href'] as String?,
                title: item['title'] as String? ?? '',
                fingerprint: md5);
            walk(item['children'] as List? ?? []);
          }
        }

        walk(data['toc'] as List? ?? []);
      } else if (tool == 'current_chapter_content' ||
          tool == 'chapter_content_by_href') {
        final content = '${data['content'] ?? ''}';
        cite(data,
            book: bookId,
            chapterHref: href,
            title: chapter,
            fingerprint: md5,
            quote: content.length > 240 ? content.substring(0, 240) : content);
      }
    }
    return jsonEncode(root);
  }
}
