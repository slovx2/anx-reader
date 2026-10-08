import 'dart:async';
import 'package:anx_reader/service/ai/citation_navigation.dart';

import 'package:anx_reader/widgets/ai/chat_scroll_controller.dart';
import 'package:anx_reader/enums/ai_reasoning_effort.dart';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/hint_key.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/providers/ai_chat.dart';
import 'package:anx_reader/providers/ai_history.dart';
import 'package:anx_reader/providers/ai_providers.dart';
import 'package:anx_reader/service/ai/ai_services.dart';
import 'package:anx_reader/service/ai/ai_history.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/utils/ai_reasoning_parser.dart';
import 'package:anx_reader/widgets/ai/model_picker_dialog.dart';
import 'package:anx_reader/widgets/ai/tool_step_tile.dart';
import 'package:anx_reader/widgets/ai/tool_tiles/apply_book_tags_step_tile.dart';
import 'package:anx_reader/widgets/ai/tool_tiles/mindmap_step_tile.dart';
import 'package:anx_reader/widgets/ai/tool_tiles/organize_bookshelf_step_tile.dart';
import 'package:anx_reader/widgets/common/anx_button.dart';
import 'package:anx_reader/widgets/common/container/filled_container.dart';
import 'package:anx_reader/widgets/delete_confirm.dart';
import 'package:anx_reader/widgets/markdown/styled_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:langchain_core/chat_models.dart';

import 'package:anx_reader/models/ai_quick_prompt_chip.dart';

class AiChatStream extends ConsumerStatefulWidget {
  const AiChatStream({
    super.key,
    this.initialMessage,
    this.sendImmediate = false,
    this.quickPromptChips = const [],
    this.trailing,
  });

  final String? initialMessage;
  final bool sendImmediate;
  final List<AiQuickPromptChip> quickPromptChips;
  final List<Widget>? trailing;

  @override
  ConsumerState<AiChatStream> createState() => AiChatStreamState();
}

class AiChatStreamState extends ConsumerState<AiChatStream> {
  final TextEditingController inputController = TextEditingController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ChatScrollController _scrollController = ChatScrollController();
  late final AiChat _chatNotifier;
  bool get _isBusy => _chatNotifier.isRunning;
  late List<String> _suggestedPrompts;
  late List<String> _starterPrompts;
  double _fontSize = 14.0;

  List<Map<String, String>> _getQuickPrompts(BuildContext context) {
    return [
      {
        'label': L10n.of(context).aiQuickPromptExplain,
        'prompt': L10n.of(context).aiQuickPromptExplainText,
      },
      {
        'label': L10n.of(context).aiQuickPromptOpinion,
        'prompt': L10n.of(context).aiQuickPromptOpinionText,
      },
      {
        'label': L10n.of(context).aiQuickPromptSummary,
        'prompt': L10n.of(context).aiQuickPromptSummaryText,
      },
      {
        'label': L10n.of(context).aiQuickPromptAnalyze,
        'prompt': L10n.of(context).aiQuickPromptAnalyzeText,
      },
      {
        'label': L10n.of(context).aiQuickPromptSuggest,
        'prompt': L10n.of(context).aiQuickPromptSuggestText,
      },
    ];
  }

  @override
  void initState() {
    super.initState();
    _chatNotifier = ref.read(aiChatProvider.notifier);
    _starterPrompts = [
      L10n.of(navigatorKey.currentContext!).quickPrompt1,
      L10n.of(navigatorKey.currentContext!).quickPrompt2,
      L10n.of(navigatorKey.currentContext!).quickPrompt3,
      L10n.of(navigatorKey.currentContext!).quickPrompt4,
      L10n.of(navigatorKey.currentContext!).quickPrompt5,
      L10n.of(navigatorKey.currentContext!).quickPrompt6,
      L10n.of(navigatorKey.currentContext!).quickPrompt7,
      L10n.of(navigatorKey.currentContext!).quickPrompt8,
      L10n.of(navigatorKey.currentContext!).quickPrompt9,
      L10n.of(navigatorKey.currentContext!).quickPrompt10,
      L10n.of(navigatorKey.currentContext!).quickPrompt11,
      L10n.of(navigatorKey.currentContext!).quickPrompt12,
    ];
    _fontSize = Prefs().aiChatFontSize;
    inputController.text = widget.initialMessage ?? '';
    _suggestedPrompts = _pickSuggestedPrompts();
    if (widget.sendImmediate) {
      _sendMessage();
    }
    _scrollToBottom();
  }

  @override
  void dispose() {
    // 运行由 aiChatProvider 持有，关闭界面不中断 Agent。
    inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  AiProvider? _currentProvider(List<AiProvider> enabledProviders) {
    final selectedId = Prefs().selectedAiService;
    try {
      return enabledProviders.firstWhere((p) => p.id == selectedId);
    } catch (_) {
      return enabledProviders.isNotEmpty ? enabledProviders.first : null;
    }
  }

  String _modelLabel(AiProvider provider) {
    final model = provider.model;
    if (model.trim().isNotEmpty) return model;
    // Fallback: look up default model from built-in templates
    final defaults = buildDefaultAiServices();
    for (final d in defaults) {
      if (d.identifier == provider.id) return d.defaultModel;
    }
    return '';
  }

  void _onProviderSelected(String providerId) {
    if (_isBusy) return;
    ref.read(aiProvidersProvider.notifier).setSelectedProvider(providerId);
    final provider =
        ref.read(aiProvidersProvider.notifier).getProviderById(providerId);
    if (provider != null) {
      ref.read(aiChatProvider.notifier).setOptions(provider);
    }
  }

  AiProvider? _providerById(List<AiProvider> providers, String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  List<String> _pickSuggestedPrompts() {
    final prompts = List<String>.from(_starterPrompts)..shuffle();
    return prompts.take(3).toList(growable: false);
  }

  void _scrollToBottom({bool reset = false}) {
    _scrollController.followToBottom(reset: reset);
  }

  Widget _buildHistoryDrawer(BuildContext context) {
    final historyState = ref.watch(aiHistoryProvider);
    return SafeArea(
      child: Column(
        children: [
          ListTile(
            title: Text(L10n.of(context).conversationHistory),
            trailing: DeleteConfirm(
              delete: () => _confirmClearHistory(context),
              deleteIcon: Icon(Icons.delete_sweep),
            ),
          ),
          Expanded(
            child: historyState.when(
              data: (items) {
                if (items.isEmpty) {
                  return Center(
                    child: Text(L10n.of(context).noConversationTip),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final entry = items[index];
                    return _buildHistoryTile(context, entry);
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(
                child: Text(L10n.of(context).failedToLoadHistoryTip),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTile(BuildContext context, AiChatHistoryEntry entry) {
    final allProviders = ref.watch(aiProvidersProvider);
    final provider = _providerById(allProviders, entry.serviceId);
    final statusColor =
        entry.completed ? Colors.green : Theme.of(context).colorScheme.tertiary;
    final title = _deriveTitle(entry);
    final subtitle = _buildHistorySubtitle(provider, entry);

    return FilledContainer(
      margin: EdgeInsets.symmetric(horizontal: 8),
      padding: EdgeInsets.all(8),
      radius: 15,
      child: GestureDetector(
        onTap: () => _handleHistoryTap(context, entry),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Text(
                      _formatTimestamp(entry.updatedAt),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
                Spacer(),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.circle, size: 10, color: statusColor),
                    DeleteConfirm(
                        delete: () => _confirmDeleteHistory(context, entry)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _buildHistorySubtitle(AiProvider? provider, AiChatHistoryEntry entry) {
    final serviceLabel = provider?.title ?? entry.serviceId;
    if (entry.model.isEmpty) {
      return serviceLabel;
    }
    return '$serviceLabel · ${entry.model}';
  }

  Widget? _providerLogo(AiProvider? provider) {
    final logo = provider?.logoAsset;
    if (logo == null || logo.isEmpty) return null;
    return Image.asset(
      logo,
      width: 20,
      height: 20,
      errorBuilder: (_, __, ___) => const SizedBox(),
    );
  }

  String _deriveTitle(AiChatHistoryEntry entry) {
    for (final message in entry.messages) {
      if (message is HumanChatMessage) {
        final content = message.contentAsString.trim();
        if (content.isNotEmpty) {
          final firstLine = content.split('\n').first.trim();
          return firstLine;
        }
      }
    }
    if (entry.messages.isNotEmpty) {
      return 'Conversation';
    }
    return 'Empty conversation';
  }

  String _formatTimestamp(int timestamp) {
    final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final date =
        '${dateTime.year}-${twoDigits(dateTime.month)}-${twoDigits(dateTime.day)}';
    final time = '${twoDigits(dateTime.hour)}:${twoDigits(dateTime.minute)}';
    return '$date $time';
  }

  Future<void> _handleHistoryTap(
    BuildContext context,
    AiChatHistoryEntry entry,
  ) async {
    if (_isBusy) {
      await _cancelStreaming();
    }

    final latestEntry =
        ref.read(aiHistoryProvider.notifier).findById(entry.id) ?? entry;
    ref.read(aiChatProvider.notifier).loadHistoryEntry(latestEntry);

    if (!context.mounted) return;
    Navigator.of(context).pop();
    _scrollToBottom(reset: true);
  }

  Future<void> _confirmDeleteHistory(
    BuildContext context,
    AiChatHistoryEntry entry,
  ) async {
    if (_isBusy && _chatNotifier.currentSessionId == entry.id) {
      await _cancelStreaming();
    }
    if (!mounted) return;
    await ref.read(aiHistoryProvider.notifier).remove(entry.id);

    final currentSessionId = ref.read(aiChatProvider.notifier).currentSessionId;
    if (currentSessionId == entry.id) {
      ref.read(aiChatProvider.notifier).clear();
    }
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    if (_isBusy) await _cancelStreaming();
    if (!mounted) return;
    await ref.read(aiHistoryProvider.notifier).clear();
    ref.read(aiChatProvider.notifier).clear();
  }

  void _sendMessage() {
    if (_isBusy) {
      return;
    }

    if (inputController.text.trim().isEmpty) return;
    final message = inputController.text.trim();
    inputController.clear();
    _scrollToBottom(reset: true);
    _chatNotifier.send(message);
  }

  void _useQuickPrompt(String prompt, {bool sendImmediately = false}) {
    final existing = inputController.text.trim();
    inputController.text = existing.isEmpty ? prompt : '$prompt $existing';
    inputController.selection = TextSelection.collapsed(
      offset: inputController.text.length,
    );
    if (sendImmediately) {
      _sendMessage();
    }
  }

  void _clearMessage() {
    if (_isBusy) {
      return;
    }
    setState(() {
      ref.read(aiChatProvider.notifier).clear();
      _suggestedPrompts = _pickSuggestedPrompts();
    });
  }

  void _regenerateLastMessage() {
    if (_isBusy) {
      return;
    }
    final messages = ref.read(aiChatProvider).value;
    if (messages == null || messages.isEmpty) {
      return;
    }

    for (int i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message is HumanChatMessage) {
        final history = messages.take(i).toList(growable: false);
        ref.read(aiChatProvider.notifier).restore(history);
        setState(() {
          inputController.text = message.contentAsString;
          _sendMessage();
        });
        break;
      }
    }
  }

  void _copyMessageContent(String content) {
    final parsed = parseReasoningContent(content);
    final clipboardText = _buildCopyableText(parsed, content);
    Clipboard.setData(ClipboardData(text: clipboardText));
    AnxToast.show(L10n.of(context).notesPageCopied);
  }

  Future<void> _cancelStreaming() async {
    if (!_isBusy) return;
    await _chatNotifier.stop();
  }

  Future<void> _showChatOptions(AiProvider provider) async {
    final notifier = ref.read(aiChatProvider.notifier);
    notifier.configure(provider);
    final l10n = L10n.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(l10n.aiModelSwitchTitle),
              subtitle: Text(_modelLabel(provider)),
              onTap: () => Navigator.pop(context, 'model'),
            ),
            if (provider.protocol.isOpenAi) ...[
              const Divider(),
              ListTile(title: Text(l10n.settingsAiProviderReasoningEffort)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<AiReasoningEffort>(
                  showSelectedIcon: false,
                  selected: {notifier.session.reasoning},
                  segments: [
                    for (final effort in AiReasoningEffort.values)
                      ButtonSegment(
                          value: effort,
                          label: Text(switch (effort) {
                            AiReasoningEffort.auto => l10n.aiChatOptionDefault,
                            AiReasoningEffort.low =>
                              l10n.settingsAiProviderReasoningEffortLow,
                            AiReasoningEffort.medium =>
                              l10n.settingsAiProviderReasoningEffortMedium,
                            AiReasoningEffort.high =>
                              l10n.settingsAiProviderReasoningEffortHigh,
                          })),
                  ],
                  onSelectionChanged: (values) =>
                      Navigator.pop(context, 'reasoning:${values.first.code}'),
                ),
              ),
              const Divider(),
              ListTile(title: Text(l10n.aiChatServiceTier)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  selected: {notifier.session.priority},
                  segments: [
                    ButtonSegment(
                        value: false, label: Text(l10n.aiChatOptionDefault)),
                    ButtonSegment(
                        value: true, label: Text(l10n.aiChatPriority)),
                  ],
                  onSelectionChanged: (values) => Navigator.pop(
                      context, values.first ? 'priority' : 'default'),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
    if (!mounted || _isBusy || choice == null) return;
    if (choice == 'model') {
      final selected = await showModelPickerDialog(
        context: context,
        provider: provider,
        currentModel: provider.model,
      );
      if (!mounted ||
          _isBusy ||
          selected == null ||
          selected == provider.model) {
        return;
      }
      final updated = provider.copyWith(model: selected);
      ref.read(aiProvidersProvider.notifier).updateProvider(updated);
      await notifier.setOptions(updated);
    } else if (choice.startsWith('reasoning:')) {
      await notifier.setOptions(provider,
          reasoning: AiReasoningEffort.fromCode(choice.split(':').last));
    } else {
      await notifier.setOptions(provider, priority: choice == 'priority');
    }
  }

  void _showFontSizeMenu(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    final offset = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final size = renderBox?.size ?? Size.zero;

    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy + size.height,
        offset.dx + size.width,
        offset.dy + size.height + 1,
      ),
      items: [
        PopupMenuItem(
          enabled: false,
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: StatefulBuilder(
            builder: (context, setMenuState) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    L10n.of(context).aiChatFontSize,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Row(
                    children: [
                      Text(
                        '${_fontSize.round()}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Expanded(
                        child: Slider(
                          value: _fontSize,
                          min: 10.0,
                          max: 24.0,
                          divisions: 14,
                          onChanged: (value) {
                            setMenuState(() {});
                            setState(() {
                              _fontSize = value;
                            });
                            Prefs().aiChatFontSize = value;
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  ChatMessage? _getLastAssistantMessage() {
    final messages = ref.watch(aiChatProvider).asData?.value;
    if (messages == null || messages.isEmpty) {
      return null;
    }

    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i] is AIChatMessage) {
        return messages[i];
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // 运行状态与消息都来自 aiChatProvider，重新打开界面时直接接上后台运行。
    final chatState = ref.watch(aiChatProvider);
    ref.listen(aiChatProvider, (_, __) {
      if (_isBusy) _scrollToBottom();
    });
    final quickPrompts = _getQuickPrompts(context);
    final allProviders = ref.watch(aiProvidersProvider);
    final enabledProviders = allProviders.where((p) => p.enabled).toList();
    final currentProvider = _currentProvider(enabledProviders);
    final selectedId = Prefs().selectedAiService;

    var aiService = PopupMenuButton<String>(
      enabled: !_isBusy,
      onSelected: _onProviderSelected,
      itemBuilder: (context) {
        return enabledProviders.map((provider) {
          final isSelected = provider.id == selectedId;
          final label = _modelLabel(provider);
          final logo = _providerLogo(provider);
          return PopupMenuItem<String>(
            value: provider.id,
            child: Row(
              children: [
                if (logo != null) logo else const SizedBox(width: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label.isNotEmpty
                        ? '${provider.title} · $label'
                        : provider.title,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isSelected) const Icon(Icons.check, size: 16),
              ],
            ),
          );
        }).toList(growable: false);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_providerLogo(currentProvider) != null)
            _providerLogo(currentProvider)!,
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              currentProvider != null
                  ? () {
                      final label = _modelLabel(currentProvider);
                      return label.isNotEmpty
                          ? '${currentProvider.title} · $label'
                          : currentProvider.title;
                    }()
                  : '',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, size: 16),
        ],
      ),
    );
    Widget inputBox = FilledContainer(
      padding: const EdgeInsets.all(4),
      radius: 15,
      child: SafeArea(
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SizedBox.shrink(),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      spacing: 8,
                      children: quickPrompts.map((prompt) {
                        return ActionChip(
                          // labelPadding: EdgeInsets.all(0),
                          label: Text(prompt['label']!),
                          onPressed: () => _useQuickPrompt(prompt['prompt']!),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 4),
            TextField(
              controller: inputController,
              decoration: InputDecoration(
                isDense: true,
                hintText: L10n.of(context).aiHintInputPlaceholder,
                border: InputBorder.none,
              ),
              maxLines: 5,
              minLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
            ),
            SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(child: aiService),
                      if (currentProvider != null)
                        IconButton(
                          icon: const Icon(Icons.tune, size: 16),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          visualDensity: VisualDensity.compact,
                          onPressed: _isBusy
                              ? null
                              : () => _showChatOptions(currentProvider),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(_isBusy ? Icons.stop : Icons.send, size: 18),
                  onPressed: _isBusy ? _cancelStreaming : _sendMessage,
                ),
              ],
            ),
          ],
        ),
      ),
    );

    Widget buildEmptyState() {
      final theme = Theme.of(context);

      Widget buildQuickChipColumn() {
        if (widget.quickPromptChips.isEmpty) {
          return const SizedBox.shrink();
        }

        final chips = <Widget>[];
        for (var i = 0; i < widget.quickPromptChips.length; i++) {
          final chip = widget.quickPromptChips[i];
          chips.add(
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8.0),
              child: GestureDetector(
                onLongPress: () =>
                    _useQuickPrompt(chip.prompt, sendImmediately: true),
                child: ActionChip(
                  avatar: Icon(chip.icon, size: 18),
                  label: Text(chip.label),
                  onPressed: () => _useQuickPrompt(chip.prompt),
                ),
              ),
            ),
          );
        }

        return Positioned(
          right: 16,
          bottom: 16,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.3,
            child: SingleChildScrollView(
              // scrollDirection: Axis.horizontal,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: chips,
              ),
            ),
          ),
        );
      }

      return Stack(
        children: [
          if (widget.quickPromptChips.isEmpty)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    L10n.of(context).tryAQuickPrompt,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: _suggestedPrompts
                        .map(
                          (prompt) => GestureDetector(
                            onLongPress: () => _useQuickPrompt(
                              prompt,
                              sendImmediately: true,
                            ),
                            child: ActionChip(
                              label: Text(prompt),
                              onPressed: () => _useQuickPrompt(prompt),
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
              ),
            ),
          buildQuickChipColumn(),
        ],
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(L10n.of(context).aiChat),
        leading: IconButton(
          icon: const Icon(Icons.insert_drive_file),
          tooltip: L10n.of(context).history,
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_document),
            onPressed: _clearMessage,
          ),
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showFontSizeMenu(context),
            ),
          ),
          if (widget.trailing != null) ...widget.trailing!,
        ],
      ),
      drawer: Drawer(
        child: _buildHistoryDrawer(context),
      ),
      body: EnvVar.isAppStore &&
              Prefs().shouldShowHint(HintKey.aiDataSharingConsent)
          ? _buildDataSharingConsent(context)
          : Column(
              children: [
                Expanded(
                  child: chatState.when(
                    data: (messages) {
                      if (messages.isEmpty) {
                        return buildEmptyState();
                      }

                      return _buildMessageList(messages);
                    },
                    loading: () => Skeletonizer.zone(child: Bone.multiText()),
                    error: (error, stack) =>
                        Center(child: Text('error: $error')),
                  ),
                ),
                inputBox,
              ],
            ),
    );
  }

  Widget _buildDataSharingConsent(BuildContext context) {
    final theme = Theme.of(context);
    final maxWidth = MediaQuery.of(context).size.width * 0.9;
    final constrainedWidth = maxWidth > 500 ? 500.0 : maxWidth;

    return Container(
      color: theme.colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constrainedWidth),
            child: FilledContainer(
              padding: const EdgeInsets.all(24),
              radius: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.privacy_tip_outlined,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    L10n.of(context).aiDataSharingTitle,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    L10n.of(context).aiDataSharingContent,
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  AnxButton(
                    onPressed: () {
                      Prefs().setShowHint(HintKey.aiDataSharingConsent, false);
                      setState(() {});
                    },
                    child: Text(L10n.of(context).aiDataSharingAgree),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(List<ChatMessage> messages) {
    return NotificationListener<ScrollNotification>(
      onNotification: _scrollController.handleNotification,
      child: ListView.builder(
        controller: _scrollController,
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final message = messages[index];
          final isStreaming = _isBusy && index == messages.length - 1;
          return _buildMessageItem(message, index, isStreaming);
        },
      ),
    );
  }

  Widget _buildMessageItem(
    ChatMessage message,
    int index,
    bool isStreaming,
  ) {
    final isUser = message is HumanChatMessage;
    final content = chatMessageDisplayContent(message);
    final parsed = parseReasoningContent(content);
    final isLongMessage = content.length > 300;
    final lastAssistantMessage = _getLastAssistantMessage();

    return Padding(
      padding: EdgeInsets.only(
        bottom: 8.0,
        left: isUser ? 8.0 : 0,
        right: isUser ? 0 : 8.0,
      ),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isUser
                    ? Theme.of(context).colorScheme.surfaceContainer
                    : Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.only(
                  topLeft: isUser ? const Radius.circular(12) : Radius.zero,
                  topRight: isUser ? Radius.zero : const Radius.circular(12),
                  bottomLeft: isUser ? Radius.zero : const Radius.circular(12),
                  bottomRight: isUser ? const Radius.circular(12) : Radius.zero,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  isUser
                      ? _buildCollapsibleText(content, isLongMessage)
                      : _buildAssistantTimeline(parsed, isStreaming),
                  if (!isUser)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (identical(message, lastAssistantMessage))
                          TextButton(
                            onPressed: _regenerateLastMessage,
                            child: Text(L10n.of(context).aiRegenerate),
                          ),
                        TextButton(
                          onPressed: () => _copyMessageContent(content),
                          child: Text(L10n.of(context).commonCopy),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  String _buildCopyableText(ParsedReasoning parsed, String fallback) {
    final buffer = StringBuffer();
    var hasWrittenSection = false;

    void startSection() {
      if (hasWrittenSection) {
        buffer.writeln();
      } else {
        hasWrittenSection = true;
      }
    }

    // void appendField(String label, String? value) {
    //   final trimmed = value?.trim();
    //   if (trimmed != null && trimmed.isNotEmpty) {
    //     buffer.writeln('$label: $trimmed');
    //   }
    // }

    for (final entry in parsed.timeline) {
      switch (entry.type) {
        case ParsedReasoningEntryType.reply:
          final text = entry.text?.trim();
          if (text != null && text.isNotEmpty) {
            startSection();
            buffer.writeln(text);
          }
          break;
        case ParsedReasoningEntryType.tool:
          // final step = entry.toolStep;
          // if (step != null) {
          //   startSection();
          //   buffer.writeln('[${step.name} (${step.status})]');
          //   appendField('Input', step.input);
          //   appendField('Output', step.output);
          //   appendField('Error', step.error);
          // }
          break;
      }
    }

    final copyText = buffer.toString().trimRight();
    if (copyText.isEmpty) {
      return fallback;
    }
    return copyText;
  }

  Widget _buildAssistantTimeline(ParsedReasoning parsed, bool isStreaming) {
    if (parsed.timeline.isEmpty) {
      return isStreaming
          ? Skeletonizer.zone(child: Bone.multiText())
          : const SizedBox.shrink();
    }

    final reasoningWidgets = _buildTimelineWidgets(
      parsed.reasoningTimeline,
      fontSize: (_fontSize - 1).clamp(11.0, _fontSize).toDouble(),
    );
    final answerWidgets = _buildTimelineWidgets(
      parsed.answerTimeline,
      fontSize: _fontSize,
    );
    final widgets = <Widget>[];

    if (reasoningWidgets.isNotEmpty) {
      widgets.add(_buildThinkingPanel(reasoningWidgets));
    }
    if (answerWidgets.isNotEmpty) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: 8));
      }
      widgets.addAll(answerWidgets);
    } else if (widgets.isEmpty && isStreaming) {
      widgets.add(Skeletonizer.zone(child: Bone.multiText()));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  List<Widget> _buildTimelineWidgets(
    List<ParsedReasoningEntry> timeline, {
    required double fontSize,
  }) {
    final widgets = <Widget>[];
    for (var i = 0; i < timeline.length; i++) {
      final entry = timeline[i];
      switch (entry.type) {
        case ParsedReasoningEntryType.reply:
          if (entry.text != null && entry.text!.trim().isNotEmpty) {
            widgets.add(
              StyledMarkdown(
                data: entry.text!,
                onLinkTap: (href) {
                  if (Uri.tryParse(href)?.scheme != 'anx') return false;
                  unawaited(openAiCitation(context, ref,
                      ref.read(aiChatProvider.notifier).session, href));
                  return true;
                },
                selectable: true,
                fontSize: fontSize,
              ),
            );
          }
          break;
        case ParsedReasoningEntryType.tool:
          if (entry.toolStep != null) {
            widgets.add(_buildToolTile(entry.toolStep!));
          }
          break;
      }

      if (i != timeline.length - 1) {
        widgets.add(const SizedBox(height: 8));
      }
    }
    return widgets;
  }

  Widget _buildThinkingPanel(List<Widget> children) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.secondary.withValues(alpha: 0.82);
    final subtleColor = theme.colorScheme.secondary.withValues(alpha: 0.68);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: false,
        dense: true,
        visualDensity: VisualDensity.compact,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.fromLTRB(28, 2, 0, 8),
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: subtleColor,
        collapsedIconColor: subtleColor,
        leading: Icon(
          Icons.psychology_alt_outlined,
          size: 15,
          color: accentColor,
        ),
        title: Text(
          L10n.of(context).aiThinkingHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: accentColor,
            fontSize: 12,
          ),
        ),
        children: [
          Container(
            margin: const EdgeInsets.only(left: 7),
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: subtleColor.withValues(alpha: 0.55),
                  width: 1,
                ),
              ),
            ),
            child: Opacity(
              opacity: 0.9,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolTile(ParsedToolStep step) {
    if (step.name == 'bookshelf_organize') {
      return OrganizeBookshelfStepTile(step: step);
    }
    if (step.name == 'mindmap_draw') {
      return MindmapStepTile(step: step);
    }
    if (step.name == 'apply_book_tags') {
      return ApplyBookTagsStepTile(step: step);
    }
    return ToolStepTile(step: step);
  }

  Widget _buildCollapsibleText(String text, bool isLongMessage) {
    if (!isLongMessage) {
      return SelectableText(
        text,
        style: TextStyle(fontSize: _fontSize),
        selectionControls: MaterialTextSelectionControls(),
      );
    }

    return _CollapsibleText(text: text, fontSize: _fontSize);
  }
}

class _CollapsibleText extends StatefulWidget {
  const _CollapsibleText({required this.text, this.fontSize = 14.0});

  final String text;
  final double fontSize;

  @override
  State<_CollapsibleText> createState() => _CollapsibleTextState();
}

class _CollapsibleTextState extends State<_CollapsibleText> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isExpanded)
          SelectableText(
            widget.text,
            style: TextStyle(fontSize: widget.fontSize),
            selectionControls: MaterialTextSelectionControls(),
          )
        else
          Stack(
            children: [
              SelectableText(
                widget.text.substring(0, 300),
                style: TextStyle(fontSize: widget.fontSize),
                selectionControls: MaterialTextSelectionControls(),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Theme.of(context)
                            .colorScheme
                            .surfaceContainer
                            .withValues(alpha: 0),
                        Theme.of(context).colorScheme.surfaceContainer,
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        TextButton(
          onPressed: () {
            setState(() {
              _isExpanded = !_isExpanded;
            });
          },
          child: Text(_isExpanded
              ? L10n.of(context).aiHintCollapse
              : L10n.of(context).aiHintExpand),
        ),
      ],
    );
  }
}
