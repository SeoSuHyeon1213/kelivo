import 'permission_mode.dart';
import 'permission_rule.dart';

class WorkspaceBinding {
  static const String keyId = 'workspace.id';
  static const String keyCwd = 'workspace.cwd';
  static const String keyToolsUsed = 'workspace.tools_used';
  static const String keyAllowAll = 'workspace.allowAll';
  static const String keyPermissionMode = 'workspace.permissionMode';
  static const String keyPermissionRules = 'workspace.permissionRules';

  final String? workspaceId;
  final String cwd;
  final bool toolsUsed;
  final PermissionMode permissionMode;
  final List<PermissionRule> permissionRules;
  bool get allowAll => permissionMode == PermissionMode.fullAccess;

  const WorkspaceBinding({
    this.workspaceId,
    this.cwd = '',
    this.toolsUsed = false,
    this.permissionRules = const [],
    bool allowAll = false,
    PermissionMode permissionMode = PermissionMode.requestApproval,
  }) : permissionMode = allowAll ? PermissionMode.fullAccess : permissionMode;

  bool get isBound => workspaceId != null && workspaceId!.isNotEmpty;

  /// True when extras name a workspace that [exists] still finds.
  static bool extrasHaveWorkspace(
    Map<String, dynamic>? extras,
    bool Function(String id) exists,
  ) {
    final binding = WorkspaceBinding.fromExtras(
      extras ?? const <String, dynamic>{},
    );
    return binding.isBound && exists(binding.workspaceId!);
  }

  factory WorkspaceBinding.fromExtras(Map<String, dynamic> extras) {
    return WorkspaceBinding(
      workspaceId: extras[keyId] as String?,
      cwd: (extras[keyCwd] as String?) ?? '',
      toolsUsed: extras[keyToolsUsed] as bool? ?? false,
      // Legacy allowAll is deliberately not imported as a new full-access grant.
      permissionMode: permissionModeFromJson(extras[keyPermissionMode]),
      permissionRules: List.unmodifiable(
        (extras[keyPermissionRules] as List? ?? const []).map(
          (entry) =>
              PermissionRule.fromJson(Map<String, dynamic>.from(entry as Map)),
        ),
      ),
    );
  }

  /// Returns a new map with this binding written. Unbound bindings remove the
  /// workspace keys instead of leaving empty values behind.
  Map<String, dynamic> applyTo(Map<String, dynamic> extras) {
    final next = Map<String, dynamic>.from(extras);
    if (!isBound) {
      next.remove(keyId);
      next.remove(keyCwd);
      next.remove(keyToolsUsed);
      next.remove(keyAllowAll);
      next.remove(keyPermissionMode);
      next.remove(keyPermissionRules);
      return next;
    }
    next[keyId] = workspaceId;
    next[keyCwd] = cwd;
    next[keyToolsUsed] = toolsUsed;
    next.remove(keyAllowAll);
    next[keyPermissionMode] = permissionMode.name;
    next[keyPermissionRules] = permissionRules
        .map((rule) => rule.toJson())
        .toList();
    return next;
  }
}
