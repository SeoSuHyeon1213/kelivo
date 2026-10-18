import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/models/permission_mode.dart';
import 'package:Kelivo/core/services/permissions/permission_service.dart';

void main() {
  const policy = PermissionService();

  test('every mode preserves read-only, skills and network restrictions', () {
    for (final mode in PermissionMode.values) {
      expect(
        policy.decide(
          mode: mode,
          action: PermissionAction.write,
          readOnly: true,
        ),
        PermissionDecision.deny,
      );
      expect(
        policy.decide(mode: mode, action: PermissionAction.write, skills: true),
        PermissionDecision.deny,
      );
      expect(
        policy.decide(
          mode: mode,
          action: PermissionAction.read,
          sandboxed: true,
          outsideWorkspace: true,
        ),
        PermissionDecision.deny,
      );
      expect(
        policy.decide(
          mode: mode,
          action: PermissionAction.shell,
          hasReadOnlyMounts: true,
        ),
        PermissionDecision.deny,
      );
      expect(
        policy.decide(mode: mode, action: PermissionAction.directConnection),
        PermissionDecision.deny,
      );
    }
  });

  test('request mode asks for writes, outside reads and all shells', () {
    expect(
      policy.decide(
        mode: PermissionMode.requestApproval,
        action: PermissionAction.read,
      ),
      PermissionDecision.allow,
    );
    for (final action in [
      PermissionAction.read,
      PermissionAction.write,
      PermissionAction.shell,
    ]) {
      expect(
        policy.decide(
          mode: PermissionMode.requestApproval,
          action: action,
          outsideWorkspace: true,
        ),
        PermissionDecision.requestApproval,
      );
    }
    expect(
      policy.decide(
        mode: PermissionMode.requestApproval,
        action: PermissionAction.write,
      ),
      PermissionDecision.requestApproval,
    );
  });

  test(
    'policy mode permits internal writes but never guesses safe commands',
    () {
      expect(
        policy.decide(
          mode: PermissionMode.policyAuto,
          action: PermissionAction.write,
        ),
        PermissionDecision.allow,
      );
      expect(
        policy.decide(
          mode: PermissionMode.policyAuto,
          action: PermissionAction.write,
          outsideWorkspace: true,
        ),
        PermissionDecision.requestApproval,
      );
      expect(
        policy.decide(
          mode: PermissionMode.policyAuto,
          action: PermissionAction.shell,
        ),
        PermissionDecision.requestApproval,
      );
    },
  );

  test('clipboard asks unless the conversation has full access', () {
    for (final action in [
      PermissionAction.clipboardRead,
      PermissionAction.clipboardWrite,
    ]) {
      expect(
        policy.decide(mode: PermissionMode.requestApproval, action: action),
        PermissionDecision.requestApproval,
      );
      expect(
        policy.decide(mode: PermissionMode.policyAuto, action: action),
        PermissionDecision.requestApproval,
      );
      expect(
        policy.decide(mode: PermissionMode.fullAccess, action: action),
        PermissionDecision.allow,
      );
    }
  });

  test('explicit full access permits outside file operations', () {
    for (final action in [
      PermissionAction.read,
      PermissionAction.write,
      PermissionAction.shell,
    ]) {
      expect(
        policy.decide(
          mode: PermissionMode.fullAccess,
          action: action,
          outsideWorkspace: true,
        ),
        PermissionDecision.allow,
      );
    }
  });
}
