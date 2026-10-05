import 'package:anx_reader/widgets/markdown/styled_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('原文引用显示为可点击文字，并由聊天回调接管', (tester) async {
    String? clicked;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StyledMarkdown(
      data: '文章中提到的[查看原文](anx://citation/registered-id)。',
      onLinkTap: (href) {
        clicked = href;
        return true;
      },
    ))));
    await tester.tap(find.text('查看原文', findRichText: true));
    expect(clicked, 'anx://citation/registered-id');
    expect(tester.takeException(), isNull);
  });
}
