import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/permission_mode.dart';
import '../../../core/models/permission_rule.dart';
import '../../../core/models/workspace_binding.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/workspace/workspace_paths.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/section_card.dart';
import '../../chat/widgets/tools_sheet_row.dart';
import '../workspace_layout.dart';

String permissionModeLabel(AppLocalizations l10n, PermissionMode mode) =>
    switch (mode) {
      PermissionMode.requestApproval => l10n.securityModeRequest,
      PermissionMode.policyAuto => l10n.securityModeAuto,
      PermissionMode.fullAccess => l10n.securityModeFull,
    };

/// Small settings form shared across layouts; desktop uses a bounded panel.
class WorkspacePermissionsPage extends StatefulWidget {
  const WorkspacePermissionsPage({super.key, required this.conversationId});
  final String conversationId;
  @override
  State<WorkspacePermissionsPage> createState() =>
      _WorkspacePermissionsPageState();
}

class _WorkspacePermissionsPageState extends State<WorkspacePermissionsPage> {
  final _path = TextEditingController();
  final _command = TextEditingController();
  PermissionRuleAction _action = PermissionRuleAction.read;
  PermissionRuleEffect _effect = PermissionRuleEffect.deny;
  bool _recursive = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _path.dispose();
    _command.dispose();
    super.dispose();
  }

  WorkspaceBinding _binding(ChatService chat) => WorkspaceBinding.fromExtras(
    chat.getConversation(widget.conversationId)?.extras ?? {},
  );

  Future<void> _update({
    PermissionMode? mode,
    PermissionRule? add,
    String? remove,
  }) async {
    if (_saving) return;
    final chat = context.read<ChatService>();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await chat.updateConversationExtras(widget.conversationId, (extras) {
        final current = WorkspaceBinding.fromExtras(extras);
        if (!current.isBound) throw StateError('workspace_unbound');
        return WorkspaceBinding(
          workspaceId: current.workspaceId,
          cwd: current.cwd,
          toolsUsed: current.toolsUsed,
          permissionMode: mode ?? current.permissionMode,
          permissionRules: List.unmodifiable([
            for (final rule in current.permissionRules)
              if (rule.id != remove) rule,
            if (add != null) add,
          ]),
        ).applyTo(extras);
      });
    } catch (_) {
      if (mounted)
        setState(
          () => _error = AppLocalizations.of(context)!.securitySaveFailed,
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addRule() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final raw = _path.text.trim();
      final draft = PermissionRule.fromJson({
        'id': const Uuid().v4(),
        'action': _action.name,
        'effect': _effect.name,
        'path': raw,
        'recursive': _action != PermissionRuleAction.shell && _recursive,
        if (_action == PermissionRuleAction.shell) 'command': _command.text,
      });
      // The user grants the actual host path, including existing junctions.
      final actual = await WorkspacePaths.resolveHostPath(raw);
      if (!mounted) return;
      await _update(
        add: PermissionRule(
          id: draft.id,
          action: draft.action,
          effect: draft.effect,
          path: actual,
          recursive: draft.recursive,
          command: draft.command,
        ),
      );
      if (mounted && _error == null) {
        _path.clear();
        _command.clear();
      }
    } catch (_) {
      if (mounted) setState(() => _error = l10n.securityRuleInvalid);
    }
  }

  String _actionLabel(AppLocalizations l10n, PermissionRuleAction action) =>
      switch (action) {
        PermissionRuleAction.read => l10n.securityRuleRead,
        PermissionRuleAction.write => l10n.securityRuleWrite,
        PermissionRuleAction.shell => l10n.securityRuleShell,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final binding = _binding(context.watch<ChatService>());
    final desktop = useDesktopWorkspaceLayout(context);
    final content = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          children: [
            for (final mode in PermissionMode.values)
              IosCardPress(
                key: ValueKey('permission-mode-${mode.name}'),
                baseColor: Colors.transparent,
                padding: const EdgeInsets.all(12),
                onTap: !binding.isBound || _saving
                    ? null
                    : () => unawaited(_update(mode: mode)),
                child: Row(
                  children: [
                    const Icon(Lucide.Shield, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            permissionModeLabel(l10n, mode),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(switch (mode) {
                            PermissionMode.requestApproval =>
                              l10n.securityModeRequestHint,
                            PermissionMode.policyAuto =>
                              l10n.securityModeAutoHint,
                            PermissionMode.fullAccess =>
                              l10n.securityModeFullHint,
                          }),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    IosCheckbox(
                      value: binding.permissionMode == mode,
                      onChanged: (_) {
                        if (binding.isBound && !_saving)
                          unawaited(_update(mode: mode));
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(l10n.securityIndependentLimits),
        const SizedBox(height: 16),
        Text(
          l10n.securityRulesTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(l10n.securityRulesHint),
        const SizedBox(height: 8),
        for (final rule in binding.permissionRules)
          SectionCard(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${rule.effect == PermissionRuleEffect.deny ? l10n.securityRuleDeny : l10n.securityRuleAllow} · ${_actionLabel(l10n, rule.action)}',
                      ),
                      SelectableText(
                        '${rule.path}${rule.recursive ? '/*' : ''}',
                      ),
                      if (rule.command != null) SelectableText(rule.command!),
                    ],
                  ),
                ),
                IosIconButton(
                  icon: Lucide.Trash2,
                  tooltip: l10n.securityRuleRemove,
                  onTap: _saving
                      ? null
                      : () => unawaited(_update(remove: rule.id)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        SectionCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              DropdownButtonFormField<PermissionRuleAction>(
                initialValue: _action,
                decoration: InputDecoration(labelText: l10n.securityRuleAction),
                items: [
                  for (final action in PermissionRuleAction.values)
                    DropdownMenuItem(
                      value: action,
                      child: Text(_actionLabel(l10n, action)),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) setState(() => _action = value);
                      },
              ),
              DropdownButtonFormField<PermissionRuleEffect>(
                initialValue: _effect,
                decoration: InputDecoration(labelText: l10n.securityRuleEffect),
                items: [
                  DropdownMenuItem(
                    value: PermissionRuleEffect.deny,
                    child: Text(l10n.securityRuleDeny),
                  ),
                  DropdownMenuItem(
                    value: PermissionRuleEffect.allow,
                    child: Text(l10n.securityRuleAllow),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) setState(() => _effect = value);
                      },
              ),
              IosFormTextField(
                label: l10n.securityRulePath,
                controller: _path,
                inlineLabel: false,
                hintText: Platform.isWindows ? r'C:\folder' : '/folder',
                enabled: !_saving,
                autocorrect: false,
                enableSuggestions: false,
              ),
              if (_action == PermissionRuleAction.shell)
                IosFormTextField(
                  label: l10n.securityRuleCommand,
                  controller: _command,
                  inlineLabel: false,
                  maxLines: 3,
                  enabled: !_saving,
                  autocorrect: false,
                  enableSuggestions: false,
                )
              else
                ToolsSheetRow(
                  icon: Lucide.Folder,
                  label: l10n.securityRuleRecursive,
                  trailing: IosSwitch(
                    value: _recursive,
                    onChanged: (value) {
                      if (!_saving) setState(() => _recursive = value);
                    },
                  ),
                ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _saving || !binding.isBound ? null : _addRule,
                icon: const Icon(Lucide.Plus),
                label: Text(l10n.securityRuleAdd),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          tooltip: l10n.settingsPageBackButton,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.securityPermissionsTitle),
      ),
      body: desktop
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: content,
              ),
            )
          : content,
    );
  }
}
