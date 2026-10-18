import 'package:Kelivo/features/home/services/tool_approval_service.dart';
import 'package:flutter/foundation.dart';
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
        arguments: const {'q': 'same'},
        conversationId: 'conversation-a',
      );
      // A retry with identical arguments shares the pending card.
      final second = service.requestApproval(
        toolCallId: 'round-0:tool-1',
        toolName: 'lookup',
        arguments: const {'q': 'same'},
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

  group('approval scopes', () {
    test('once does not grant later calls', () async {
      final service = ToolApprovalService();
      addTearDown(service.dispose);
      final first = service.requestApproval(
        toolCallId: 'a',
        toolName: 'lookup',
        arguments: const {},
        conversationId: 'chat',
        grantKey: 'mcp:server:lookup',
      );
      service.approve('a', conversationId: 'chat');
      expect((await first).approved, isTrue);
      final second = service.requestApproval(
        toolCallId: 'b',
        toolName: 'lookup',
        arguments: const {},
        conversationId: 'chat',
        grantKey: 'mcp:server:lookup',
      );
      await expectStillPending(second);
      expect(service.hasPending, isTrue);
    });

    test(
      'conversation grant auto-approves the same key in that chat only',
      () async {
        final service = ToolApprovalService();
        addTearDown(service.dispose);
        final first = service.requestApproval(
          toolCallId: 'a',
          toolName: 'lookup',
          arguments: const {},
          conversationId: 'chat',
          grantKey: 'mcp:server:lookup',
        );
        // A parallel call with the same key is released by the grant too.
        final parallel = service.requestApproval(
          toolCallId: 'b',
          toolName: 'lookup',
          arguments: const {'q': 'other'},
          conversationId: 'chat',
          grantKey: 'mcp:server:lookup',
        );
        final otherKey = service.requestApproval(
          toolCallId: 'c',
          toolName: 'write',
          arguments: const {},
          conversationId: 'chat',
          grantKey: 'mcp:server:write',
        );
        service.approve(
          'a',
          conversationId: 'chat',
          scope: ToolApprovalScope.conversation,
        );
        expect((await first).approved, isTrue);
        expect((await parallel).approved, isTrue);
        await expectStillPending(otherKey);

        final later = await service.requestApproval(
          toolCallId: 'd',
          toolName: 'lookup',
          arguments: const {},
          conversationId: 'chat',
          grantKey: 'mcp:server:lookup',
        );
        expect(later.approved, isTrue);

        final otherChat = service.requestApproval(
          toolCallId: 'e',
          toolName: 'lookup',
          arguments: const {},
          conversationId: 'other-chat',
          grantKey: 'mcp:server:lookup',
        );
        await expectStillPending(otherChat);

        service.clearConversationGrants('chat');
        final afterClear = service.requestApproval(
          toolCallId: 'f',
          toolName: 'lookup',
          arguments: const {},
          conversationId: 'chat',
          grantKey: 'mcp:server:lookup',
        );
        await expectStillPending(afterClear);
        service.cancelAll();
      },
    );

    test('requests without a key or conversation fall back to once', () async {
      final service = ToolApprovalService();
      addTearDown(service.dispose);
      final keyless = service.requestApproval(
        toolCallId: 'a',
        toolName: 'lookup',
        arguments: const {},
        conversationId: 'chat',
      );
      expect(service.pendingRequests.single.canGrantConversation, isFalse);
      service.approve(
        'a',
        conversationId: 'chat',
        scope: ToolApprovalScope.conversation,
      );
      expect((await keyless).approved, isTrue);

      final unscoped = service.requestApproval(
        toolCallId: 'b',
        toolName: 'lookup',
        arguments: const {},
        grantKey: 'mcp:server:lookup',
      );
      expect(service.pendingRequests.single.canGrantConversation, isFalse);
      service.approve('b', scope: ToolApprovalScope.conversation);
      expect((await unscoped).approved, isTrue);
      expect(service.hasConversationGrant('chat', 'mcp:server:lookup'), isFalse);
    });

    test('always persists once and also grants the conversation', () async {
      final service = ToolApprovalService();
      addTearDown(service.dispose);
      var persisted = 0;
      final first = service.requestApproval(
        toolCallId: 'a',
        toolName: 'lookup',
        arguments: const {},
        conversationId: 'chat',
        grantKey: 'mcp:server:lookup',
        persistGrant: () async => persisted++,
      );
      expect(service.pendingRequests.single.canGrantAlways, isTrue);
      service.approve(
        'a',
        conversationId: 'chat',
        scope: ToolApprovalScope.always,
      );
      expect((await first).approved, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(persisted, 1);
      expect(service.hasConversationGrant('chat', 'mcp:server:lookup'), isTrue);
    });

    test('always without a persister only approves once', () async {
      final service = ToolApprovalService();
      addTearDown(service.dispose);
      final first = service.requestApproval(
        toolCallId: 'a',
        toolName: 'clipboard',
        arguments: const {},
        conversationId: 'chat',
        grantKey: 'clipboard:read',
      );
      expect(service.pendingRequests.single.canGrantAlways, isFalse);
      service.approve(
        'a',
        conversationId: 'chat',
        scope: ToolApprovalScope.always,
      );
      expect((await first).approved, isTrue);
      expect(service.hasConversationGrant('chat', 'clipboard:read'), isFalse);
    });

    test('a failing persister still approves the current call', () async {
      final service = ToolApprovalService();
      addTearDown(service.dispose);
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      final first = service.requestApproval(
        toolCallId: 'a',
        toolName: 'lookup',
        arguments: const {},
        conversationId: 'chat',
        grantKey: 'mcp:server:lookup',
        persistGrant: () async => throw StateError('disk full'),
      );
      service.approve(
        'a',
        conversationId: 'chat',
        scope: ToolApprovalScope.always,
      );
      expect((await first).approved, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
    });
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
