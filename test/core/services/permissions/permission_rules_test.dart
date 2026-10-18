import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/models/permission_mode.dart';
import 'package:Kelivo/core/models/permission_rule.dart';
import 'package:Kelivo/core/services/permissions/permission_service.dart';

void main() {
  const policy = PermissionService();
  const allow = PermissionRule(
    id: 'allow',
    action: PermissionRuleAction.read,
    effect: PermissionRuleEffect.allow,
    path: '/outside/data',
    recursive: true,
  );
  const deny = PermissionRule(
    id: 'deny',
    action: PermissionRuleAction.read,
    effect: PermissionRuleEffect.deny,
    path: '/outside/data/private',
    recursive: true,
  );
  test('allow applies only to policy mode; deny overrides every mode', () {
    for (final mode in PermissionMode.values) {
      expect(
        policy.decide(
          mode: mode,
          action: PermissionAction.read,
          outsideWorkspace: true,
          rules: [allow, deny],
          resource: '/outside/data/private/secret',
        ),
        PermissionDecision.deny,
      );
    }
    expect(
      policy.decide(
        mode: PermissionMode.policyAuto,
        action: PermissionAction.read,
        outsideWorkspace: true,
        rules: [allow],
        resource: '/outside/data/public',
      ),
      PermissionDecision.allow,
    );
    expect(
      policy.decide(
        mode: PermissionMode.requestApproval,
        action: PermissionAction.read,
        outsideWorkspace: true,
        rules: [allow],
        resource: '/outside/data/public',
      ),
      PermissionDecision.requestApproval,
    );
    expect(
      policy.decide(
        mode: PermissionMode.policyAuto,
        action: PermissionAction.read,
        outsideWorkspace: true,
        rules: [allow],
        resource: '/outside/database/secret',
      ),
      PermissionDecision.requestApproval,
    );
  });
  test('shell cannot bypass a file deny rule even with full access', () {
    expect(
      policy.decide(
        mode: PermissionMode.fullAccess,
        action: PermissionAction.shell,
        rules: [deny],
        resource: '/work',
        shellCommand: 'cat /outside/data/private/secret',
      ),
      PermissionDecision.deny,
    );
  });
  test('shell allow matches exact command and working directory', () {
    const shell = PermissionRule(
      id: 'shell',
      action: PermissionRuleAction.shell,
      effect: PermissionRuleEffect.allow,
      path: '/work',
      command: 'git status',
    );
    for (final (cwd, command, expected) in [
      ('/work', 'git status', PermissionDecision.allow),
      ('/work', 'git status; rm -rf .', PermissionDecision.requestApproval),
      ('/other', 'git status', PermissionDecision.requestApproval),
    ]) {
      expect(
        policy.decide(
          mode: PermissionMode.policyAuto,
          action: PermissionAction.shell,
          rules: [shell],
          resource: cwd,
          shellCommand: command,
        ),
        expected,
      );
    }
  });
  test('allow rules cannot override read-only', () {
    expect(
      policy.decide(
        mode: PermissionMode.policyAuto,
        action: PermissionAction.write,
        readOnly: true,
        rules: [
          const PermissionRule(
            id: 'write',
            action: PermissionRuleAction.write,
            effect: PermissionRuleEffect.allow,
            path: '/work',
          ),
        ],
        resource: '/work',
      ),
      PermissionDecision.deny,
    );
  });
  test('Windows paths are case-insensitive with directory boundaries', () {
    const rule = PermissionRule(
      id: 'win',
      action: PermissionRuleAction.read,
      effect: PermissionRuleEffect.allow,
      path: r'C:\Data',
      recursive: true,
    );
    expect(rule.matches('read', r'c:\data\file', windows: true), isTrue);
    expect(rule.matches('read', r'C:\Database\file', windows: true), isFalse);
  });
}
