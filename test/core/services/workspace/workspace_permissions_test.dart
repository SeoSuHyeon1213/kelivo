import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:Kelivo/core/models/permission_mode.dart';
import 'package:Kelivo/core/models/workspace.dart';
import 'package:Kelivo/core/models/workspace_binding.dart';
import 'package:Kelivo/core/services/api/tool_call_cancellation.dart';
import 'package:Kelivo/core/services/workspace/workspace_paths.dart';
import 'package:Kelivo/core/services/workspace/workspace_tools_service.dart';
import 'package:Kelivo/features/home/services/tool_approval_service.dart';
import 'package:Kelivo/utils/mcp_structured_image.dart';

void main() {
  late Directory temp;
  late Directory work;
  late Directory session;
  late Directory skills;
  late File outside;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kelivo-permissions-');
    work = Directory(p.join(temp.path, 'work'))..createSync();
    session = Directory(p.join(temp.path, 'session'))..createSync();
    skills = Directory(p.join(temp.path, 'skills'))..createSync();
    outside = File(p.join(temp.path, 'secret.txt'))
      ..writeAsStringSync('PRIVATE_SENTINEL');
  });
  tearDown(() async => temp.delete(recursive: true));

  WorkspaceToolContext context({
    PermissionMode mode = PermissionMode.requestApproval,
    WorkspaceBinding? Function()? currentBinding,
  }) {
    final now = DateTime.utc(2026);
    return WorkspaceToolContext(
      workspace: Workspace(
        id: 'ws',
        name: 'Test',
        kind: WorkspaceKind.managed,
        createdAt: now,
        updatedAt: now,
      ),
      binding: WorkspaceBinding(workspaceId: 'ws', permissionMode: mode),
      paths: WorkspacePaths.native(
        workspaceHostRoot: work.path,
        sessionHostDir: session.path,
        skillsHostDir: skills.path,
      ),
      sessionDir: session,
      outputsDir: Directory(p.join(session.path, 'outputs')),
      conversationId: 'chat',
      currentBinding: currentBinding,
    );
  }

  String content(Object? result) =>
      ClientToolResult.fromHandler(result).content;
  Future<void> waiting(ToolApprovalService approval) async {
    for (var i = 0; i < 100 && !approval.hasPending; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(approval.hasPending, isTrue);
  }

  test('outside read never returns content before approval', () async {
    final approval = ToolApprovalService();
    var done = false;
    final pending = WorkspaceToolsService().handle(
      context(),
      'read_file',
      {'path': outside.path},
      toolCallId: 'read',
      approvalService: approval,
    )..then((_) => done = true);
    await waiting(approval);
    expect(done, isFalse);
    expect(
      approval.pendingRequests.single.arguments['resolved_path'],
      outside.resolveSymbolicLinksSync(),
    );
    approval.deny('read', conversationId: 'chat');
    final result = content(await pending);
    expect(jsonDecode(result)['error'], 'approval_denied');
    expect(result, isNot(contains('PRIVATE_SENTINEL')));
  });

  test('approved outside read returns only its requested file', () async {
    final approval = ToolApprovalService();
    final pending = WorkspaceToolsService().handle(
      context(),
      'read_file',
      {'path': outside.path},
      toolCallId: 'read',
      approvalService: approval,
    );
    await waiting(approval);
    approval.approve('read', conversationId: 'chat');
    expect(content(await pending), contains('PRIVATE_SENTINEL'));
  });

  test('outside list, grep and image requests also require approval', () async {
    for (final tool in ['list_dir', 'glob', 'grep', 'view_image']) {
      final result = content(
        await WorkspaceToolsService().handle(context(), tool, {
          'path': tool == 'view_image' ? outside.path : temp.path,
          'pattern': 'PRIVATE',
        }, toolCallId: tool),
      );
      expect(jsonDecode(result)['error'], 'approval_denied', reason: tool);
      expect(result, isNot(contains('PRIVATE_SENTINEL')));
    }
  });

  test('request mode asks before writing inside the workspace', () async {
    final target = File(p.join(work.path, 'new.txt'));
    final result = await WorkspaceToolsService().handle(
      context(),
      'write_file',
      {'path': target.path, 'content': 'new'},
      toolCallId: 'write',
    );
    expect(jsonDecode(content(result))['error'], 'approval_denied');
    expect(target.existsSync(), isFalse);
  });

  test('policy auto permits an internal write but not outside reads', () async {
    final target = File(p.join(work.path, 'new.txt'));
    final tools = WorkspaceToolsService();
    await tools.handle(context(mode: PermissionMode.policyAuto), 'write_file', {
      'path': target.path,
      'content': 'new',
    }, toolCallId: 'write');
    expect(target.readAsStringSync(), 'new');
    final result = await tools.handle(
      context(mode: PermissionMode.policyAuto),
      'read_file',
      {'path': outside.path},
      toolCallId: 'read',
    );
    expect(jsonDecode(content(result))['error'], 'approval_denied');
  });

  test(
    'a symlink changed during approval cannot read a different file',
    () async {
      final link = Link(p.join(work.path, 'link.txt'));
      try {
        link.createSync(outside.path);
      } on FileSystemException {
        markTestSkipped('Symbolic link creation is not permitted on this host');
        return;
      }
      final other = File(p.join(temp.path, 'other.txt'))
        ..writeAsStringSync('OTHER_SECRET');
      final approval = ToolApprovalService();
      final pending = WorkspaceToolsService().handle(
        context(),
        'read_file',
        {'path': link.path},
        toolCallId: 'read',
        approvalService: approval,
      );
      await waiting(approval);
      link.deleteSync();
      link.createSync(other.path);
      approval.approve('read', conversationId: 'chat');
      expect(content(await pending), isNot(contains('OTHER_SECRET')));
    },
  );

  test('unbinding during approval revokes the request', () async {
    WorkspaceBinding? current = const WorkspaceBinding(workspaceId: 'ws');
    final approval = ToolApprovalService();
    final pending = WorkspaceToolsService().handle(
      context(currentBinding: () => current),
      'read_file',
      {'path': outside.path},
      toolCallId: 'read',
      approvalService: approval,
    );
    await waiting(approval);
    current = const WorkspaceBinding();
    approval.approve('read', conversationId: 'chat');
    expect(content(await pending), isNot(contains('PRIVATE_SENTINEL')));
  });

  test(
    'cancellation releases a pending approval without touching files',
    () async {
      var cancelled = false;
      final signal = Completer<void>();
      final approval = ToolApprovalService();
      final cancellation = ToolCallCancellation(
        isCancelled: () => cancelled,
        cancelled: signal.future,
      );
      final pending = cancellation.run(
        () => WorkspaceToolsService().handle(
          context(),
          'read_file',
          {'path': outside.path},
          toolCallId: 'read',
          approvalService: approval,
        ),
      );
      await waiting(approval);
      cancelled = true;
      signal.complete();
      expect(content(await pending), isNot(contains('PRIVATE_SENTINEL')));
      expect(approval.hasPending, isFalse);
    },
  );
}
