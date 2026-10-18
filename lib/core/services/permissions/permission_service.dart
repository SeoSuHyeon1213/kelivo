import '../../models/permission_mode.dart';
import '../../models/permission_rule.dart';

enum PermissionAction {
  read,
  write,
  shell,
  directConnection,
  clipboardRead,
  clipboardWrite,
}

enum PermissionDecision { allow, requestApproval, deny }

/// Shared policy. Hard restrictions always take precedence over approval mode.
class PermissionService {
  const PermissionService();

  PermissionDecision decide({
    required PermissionMode mode,
    required PermissionAction action,
    bool outsideWorkspace = false,
    bool readOnly = false,
    bool skills = false,
    bool sandboxed = false,
    bool hasReadOnlyMounts = false,
    List<PermissionRule> rules = const [],
    String? resource,
    String? shellCommand,
    bool windows = false,
  }) {
    // Tool full access never authorizes a network route change.
    if (action == PermissionAction.directConnection) {
      return PermissionDecision.deny;
    }
    if (action == PermissionAction.clipboardRead ||
        action == PermissionAction.clipboardWrite)
      return mode == PermissionMode.fullAccess
          ? PermissionDecision.allow
          : PermissionDecision.requestApproval;
    if (action == PermissionAction.write && (readOnly || skills)) {
      return PermissionDecision.deny;
    }
    if (sandboxed && outsideWorkspace) return PermissionDecision.deny;
    // PRoot cannot enforce read-only binds against arbitrary programs.
    if (action == PermissionAction.shell &&
        (hasReadOnlyMounts ||
            rules.any(
              (rule) =>
                  rule.effect == PermissionRuleEffect.deny &&
                  rule.action != PermissionRuleAction.shell,
            ))) {
      return PermissionDecision.deny;
    }
    final matches = rules.where(
      (rule) => rule.matches(
        action.name,
        resource,
        shellCommand: shellCommand,
        windows: windows,
      ),
    );
    if (matches.any((rule) => rule.effect == PermissionRuleEffect.deny))
      return PermissionDecision.deny;
    if (mode == PermissionMode.policyAuto &&
        matches.any((rule) => rule.effect == PermissionRuleEffect.allow))
      return PermissionDecision.allow;
    if (mode == PermissionMode.fullAccess) return PermissionDecision.allow;
    if (action == PermissionAction.read && !outsideWorkspace) {
      return PermissionDecision.allow;
    }
    if (mode == PermissionMode.policyAuto &&
        action == PermissionAction.write &&
        !outsideWorkspace) {
      return PermissionDecision.allow;
    }
    // Free-form shell commands are never automatically classified as safe.
    return PermissionDecision.requestApproval;
  }
}
