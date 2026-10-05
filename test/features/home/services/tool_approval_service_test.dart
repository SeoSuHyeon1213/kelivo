import 'package:Kelivo/features/home/services/tool_approval_service.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> expectStillPending(Future<dynamic> future) async {
  var completed = false;
  future.whenComplete(() {
    completed = true;
  });
  await Future<void>.delayed(Duration.zero);
  expect(completed, isFalse);
}

void main() {
  test('approval arguments cannot change after the card is created', () async {
    final service = ToolApprovalService();
    addTearDown(service.dispose);
    final arguments = <String, dynamic>{
      'path': '/work/approved',
      'nested': <String, dynamic>{'text': 'original'},
    };
    final result = service.requestApproval(
      toolCallId: 'immutable',
      toolName: 'write_file',
      arguments: arguments,
      conversationId: 'chat',
    );
    arguments['path'] = '/outside/changed';
    (arguments['nested'] as Map)['text'] = 'changed';
    final card = service.pendingRequests.single;
    expect(card.arguments['path'], '/work/approved');
    expect(card.arguments['nested']['text'], 'original');
    expect(
      () => card.arguments['path'] = '/outside/changed',
      throwsUnsupportedError,
    );
    expect(
      () => card.arguments['nested']['text'] = 'changed',
      throwsUnsupportedError,
    );
    service.deny('immutable', conversationId: 'chat');
    expect((await result).approved, isFalse);
  });
  test('same call id cannot reuse approval for different arguments', () async {
    final service = ToolApprovalService();
    addTearDown(service.dispose);
    final original = service.requestApproval(
      toolCallId: 'call',
      toolName: 'write_file',
      arguments: const {'path': '/work/approved.txt'},
      conversationId: 'chat',
    );
    final changed = await service.requestApproval(
      toolCallId: 'call',
      toolName: 'write_file',
      arguments: const {'path': '/outside/secret.txt'},
      conversationId: 'chat',
    );
    expect(changed.approved, isFalse);
    expect(changed.denyReason, 'approval_request_mismatch');
    await expectStillPending(original);
    service.approve('call', conversationId: 'chat');
    expect((await original).approved, isTrue);
  });

  test(
    'two conversations sharing a placeholder id keep both Completers',
    () async {
      final service = ToolApprovalService();
      final futureA = service.requestApproval(
        toolCallId: 'round-0:tool-1',
        toolName: 'lookup',
        arguments: const {'q': 'a'},
        conversationId: 'conversation-a',
      );
      final futureB = service.requestApproval(
        toolCallId: 'round-0:tool-1',
        toolName: 'lookup',
        arguments: const {'q': 'b'},
        conversationId: 'conversation-b',
      );

      expect(service.pendingRequests, hasLength(2));
      expect(
        service.pendingFor(
          toolCallId: 'round-0:tool-1',
          conversationId: 'conversation-a',
        ),
        isNotNull,
      );
      expect(
        service.pendingFor(
          toolCallId: 'round-0:tool-1',
          conversationId: 'conversation-b',
        ),
        isNotNull,
      );

      service.approve('round-0:tool-1', conversationId: 'conversation-a');
      final resultA = await futureA;
      expect(resultA.approved, isTrue);
      await expectStillPending(futureB);
      expect(
        service.isPending('round-0:tool-1', conversationId: 'conversation-b'),
        isTrue,
      );
      expect(
        service.isPending('round-0:tool-1', conversationId: 'conversation-a'),
        isFalse,
      );

      service.approve('round-0:tool-1', conversationId: 'conversation-b');
      final resultB = await futureB;
      expect(resultB.approved, isTrue);
      expect(service.hasPending, isFalse);
    },
  );

  test(
    'requestApproval does not overwrite an existing Completer for the same key',
    () async {
      final service = ToolApprovalService();
      final first = service.requestApproval(
        toolCallId: 'round-0:tool-1',
        toolName: 'lookup',
        arguments: const {'q': 'first'},
        conversationId: 'conversation-a',
      );
      final second = service.requestApproval(
        toolCallId: 'round-0:tool-1',
        toolName: 'lookup',
        arguments: const {'q': 'second'},
        conversationId: 'conversation-a',
      );

      expect(service.pendingRequests, hasLength(1));
      service.approve('round-0:tool-1', conversationId: 'conversation-a');
      expect((await first).approved, isTrue);
      expect((await second).approved, isTrue);
    },
  );

  test('unscoped requests with the same toolCallId do not overwrite', () async {
    final service = ToolApprovalService();
    final first = service.requestApproval(
      toolCallId: 'round-0:tool-1',
      toolName: 'lookup',
      arguments: const {'q': 'first'},
    );
    final second = service.requestApproval(
      toolCallId: 'round-0:tool-1',
      toolName: 'lookup',
      arguments: const {'q': 'second'},
    );

    expect(service.pendingRequests, hasLength(2));
    await expectStillPending(first);
    await expectStillPending(second);

    service.cancelAll();
    expect((await first).approved, isFalse);
    expect((await second).approved, isFalse);
  });

  test('cancelForConversation leaves the other chat waiting', () async {
    final service = ToolApprovalService();
    final futureA = service.requestApproval(
      toolCallId: 'round-0:tool-1',
      toolName: 'lookup',
      arguments: const {},
      conversationId: 'conversation-a',
    );
    final futureB = service.requestApproval(
      toolCallId: 'round-0:tool-1',
      toolName: 'lookup',
      arguments: const {},
      conversationId: 'conversation-b',
    );

    service.cancelForConversation('conversation-a');
    expect((await futureA).approved, isFalse);
    await expectStillPending(futureB);
    expect(
      service.pendingFor(
        toolCallId: 'round-0:tool-1',
        conversationId: 'conversation-b',
      ),
      isNotNull,
    );
  });
}
