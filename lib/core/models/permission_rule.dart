enum PermissionRuleAction { read, write, shell }

enum PermissionRuleEffect { allow, deny }

/// Explicit resource scopes only; shell rules match an entire command and cwd.
class PermissionRule {
  const PermissionRule({
    required this.id,
    required this.action,
    required this.effect,
    required this.path,
    this.recursive = false,
    this.command,
  });
  final String id;
  final PermissionRuleAction action;
  final PermissionRuleEffect effect;
  final String path;
  final bool recursive;
  final String? command;

  static String _normalize(String path, bool windows) {
    var value = path.replaceAll('\\', '/');
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return windows ? value.toLowerCase() : value;
  }

  bool matches(
    String actionName,
    String? resource, {
    String? shellCommand,
    bool windows = false,
  }) {
    if (action.name != actionName || resource == null) return false;
    final scope = _normalize(path, windows);
    final target = _normalize(resource, windows);
    if (action == PermissionRuleAction.shell)
      return target == scope && command == shellCommand;
    return target == scope ||
        (recursive &&
            target.startsWith(scope.endsWith('/') ? scope : '$scope/'));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'action': action.name,
    'effect': effect.name,
    'path': path,
    'recursive': recursive,
    if (command != null) 'command': command,
  };
  factory PermissionRule.fromJson(Map<String, dynamic> json) {
    final path = json['path'] as String;
    if (!(path.startsWith('/') ||
            RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) ||
            RegExp(r'^\\\\[^\\]+\\[^\\]+').hasMatch(path)) ||
        path.contains('\u0000') ||
        path
            .replaceAll('\\', '/')
            .split('/')
            .any((part) => part == '..' || part == '.'))
      throw const FormatException('Rule path must be absolute and canonical');
    final action = PermissionRuleAction.values.byName(json['action'] as String);
    final command = json['command'] as String?;
    if (action == PermissionRuleAction.shell &&
        (command == null || command.isEmpty))
      throw const FormatException('Shell rules require an exact command');
    return PermissionRule(
      id: json['id'] as String,
      action: action,
      effect: PermissionRuleEffect.values.byName(json['effect'] as String),
      path: path,
      recursive: json['recursive'] == true,
      command: command,
    );
  }
}
