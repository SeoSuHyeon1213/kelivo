import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../character_test_session.dart';

/// Compact switch that turns memory on or off for the active test chat.
class CharacterTestMemoryToggle extends StatelessWidget {
  const CharacterTestMemoryToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final memoryEnabled = CharacterTestSession.instance.memoryEnabled;
    return ValueListenableBuilder<bool>(
      valueListenable: memoryEnabled,
      builder: (context, enabled, _) {
        return Tooltip(
          message: l10n.assistantTestChatMemory,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Lucide.Brain,
                size: 16,
                color: enabled
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 6),
              IosSwitch(
                value: enabled,
                width: 36,
                height: 22,
                hitTestSize: 36,
                semanticLabel: l10n.assistantTestChatMemory,
                onChanged: (v) => memoryEnabled.value = v,
              ),
            ],
          ),
        );
      },
    );
  }
}
