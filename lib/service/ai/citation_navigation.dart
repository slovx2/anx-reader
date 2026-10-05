import 'dart:async';
import 'dart:io';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_session.dart';
import 'citations.dart';

bool _openingCitation = false;

Future<void> openAiCitation(BuildContext context, WidgetRef ref,
    AiChatSession session, String href) async {
  final l10n = L10n.of(context);
  if (session.status == AiRunStatus.running) {
    AnxToast.show(l10n.aiCitationWait);
    return;
  }
  if (_openingCitation) return;
  final citation = AiCitationRegistry(session).resolve(href);
  if (citation == null) {
    AnxToast.show(l10n.aiCitationUnavailable);
    return;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  final chatRoute = ModalRoute.of(context);
  final navigator = Navigator.of(context);
  _openingCitation = true;
  try {
    final book = await bookDao.selectBookById(citation['bookId'] as int);
    if (book.isDeleted || !await File(book.fileFullPath).exists()) {
      AnxToast.show(l10n.aiCitationBookUnavailable);
      return;
    }
    if (citation['md5'] != null && citation['md5'] != book.md5) {
      AnxToast.show(l10n.aiCitationFileChanged);
      return;
    }
    final cfi = citation['cfi'] as String?;
    final chapterHref = citation['href'] as String?;
    if ((cfi == null || cfi.isEmpty) &&
        (chapterHref == null || chapterHref.isEmpty)) {
      AnxToast.show(l10n.aiCitationUnavailable);
      return;
    }
    if (chatRoute is PopupRoute && chatRoute.isActive) {
      navigator.removeRoute(chatRoute);
      await chatRoute.completed;
    }
    final player = epubPlayerKey.currentState;
    if (player != null && player.widget.book.id == book.id) {
      if (cfi?.isNotEmpty == true) {
        await player.goToCfi(cfi!);
      } else {
        await player.goToHref(chapterHref!);
      }
    } else {
      final ready = Completer<void>();
      // 由阅读器加载完成后定位，href 不冒充 CFI 传入初始化恢复路径。
      final closed = pushToReadingPage(ref, navigatorKey.currentContext!, book,
          providerContainer: container, readerReady: ready);
      await Future.any([
        ready.future,
        closed.then((_) => throw StateError('Reader was not opened')),
      ]).timeout(const Duration(seconds: 45));
      final target = epubPlayerKey.currentState;
      if (target == null || target.widget.book.id != book.id) {
        throw StateError('Reader changed');
      }
      if (cfi?.isNotEmpty == true) {
        await target.goToCfi(cfi!);
      } else {
        await target.goToHref(chapterHref!);
      }
    }
  } on StateError catch (_) {
    AnxToast.show(l10n.aiCitationBookUnavailable);
  } catch (error) {
    AnxLog.warning('Citation navigation failed: $error');
    AnxToast.show(l10n.aiCitationOpenFailed);
  } finally {
    _openingCitation = false;
  }
}
