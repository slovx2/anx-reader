import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 流式内容只在用户仍停留底部时跟随；程序滚动不改变用户选择。
class ChatScrollController extends ScrollController {
  bool following = true;
  bool _scheduled = false;
  ScrollDirection _userDirection = ScrollDirection.idle;

  bool handleNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is UserScrollNotification) {
      _userDirection = notification.direction;
      if (notification.direction == ScrollDirection.forward) {
        following = false;
      } else if (notification.direction == ScrollDirection.reverse &&
          notification.metrics.extentAfter <= 24) {
        following = true;
      }
    } else if (notification is ScrollUpdateNotification &&
        _userDirection != ScrollDirection.idle) {
      following = _userDirection == ScrollDirection.reverse &&
          notification.metrics.extentAfter <= 24;
    }
    return false;
  }

  void followToBottom({bool reset = false}) {
    if (reset) following = true;
    if (!following || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!following || !hasClients) return;
      // 每帧合并更新，避免旧动画在用户拖动后继续把列表拉回底部。
      jumpTo(position.maxScrollExtent);
    });
  }
}
