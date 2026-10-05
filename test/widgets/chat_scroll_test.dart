import 'package:anx_reader/widgets/ai/chat_scroll_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('流式追加时向上滚动暂停，回到底部恢复', (tester) async {
    final controller = ChatScrollController();
    var count = 40;
    late StateSetter update;
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return NotificationListener<ScrollNotification>(
        onNotification: controller.handleNotification,
        child: ListView.builder(
            controller: controller,
            itemCount: count,
            itemExtent: 60,
            itemBuilder: (_, i) => Text('段落 $i')),
      );
    })));
    controller.followToBottom();
    await tester.pump();
    await tester.pump();
    expect(controller.position.extentAfter, 0);
    // 轻微滚轮上移也必须暂停，不能因仍在底部阈值内而被拉回。
    await tester.sendEventToBinding(PointerScrollEvent(
      position: tester.getCenter(find.byType(ListView)),
      scrollDelta: const Offset(0, -10),
    ));
    await tester.pumpAndSettle();
    expect(controller.following, false);
    final wheelOffset = controller.offset;
    update(() => count++);
    controller.followToBottom();
    await tester.pump();
    await tester.pump();
    expect(controller.offset, wheelOffset);
    await tester.drag(find.byType(ListView), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(controller.following, false);
    final offset = controller.offset;
    update(() => count += 5);
    controller.followToBottom();
    await tester.pump();
    await tester.pump();
    expect(controller.offset, closeTo(offset, 1));
    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(controller.following, true);
    update(() => count += 5);
    controller.followToBottom();
    await tester.pump();
    await tester.pump();
    expect(controller.position.extentAfter, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
