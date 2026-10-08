import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/providers/ai_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

/// AI 聊天是否正在运行；只让这个小组件随流式输出重建。
bool _watchAiRunning(WidgetRef ref) {
  ref.watch(aiChatProvider);
  return ref.read(aiChatProvider.notifier).isRunning;
}

/// AI 按钮图标：运行中时加角标。
class AiChatButtonIcon extends ConsumerWidget {
  const AiChatButtonIcon({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Badge(
      isLabelVisible: _watchAiRunning(ref),
      smallSize: 8,
      child: const Icon(Icons.auto_awesome),
    );
  }
}

/// AI 面板关闭但仍在运行时显示的悬浮标记，点击重新打开面板。
class AiRunIndicator extends ConsumerWidget {
  const AiRunIndicator({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_watchAiRunning(ref)) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return PointerInterceptor(
      child: Tooltip(
        message: L10n.of(context).aiChat,
        child: Material(
          color: colorScheme.secondaryContainer,
          shape: const StadiumBorder(),
          elevation: 2,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome,
                      size: 16, color: colorScheme.onSecondaryContainer),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
