import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Result of a tool approval request.
class ToolApprovalResult {
  final bool approved;
  final String? denyReason;

  const ToolApprovalResult({required this.approved, this.denyReason});

  factory ToolApprovalResult.approved() =>
      const ToolApprovalResult(approved: true);
  factory ToolApprovalResult.denied([String? reason]) =>
      ToolApprovalResult(approved: false, denyReason: reason);
}

/// How far a user's approval reaches beyond the current call.
enum ToolApprovalScope {
  /// Only this tool call.
  once,

  /// Matching calls in the same conversation until the app restarts.
  conversation,

  /// Persisted by the caller (MCP tool flag, workspace allow rule, ...).
  always,
}

typedef _PendingKey = ({String scope, String toolCallId});

Object? _freezeArguments(Object? value) {
  if (value is Map)
    return Map<String, dynamic>.unmodifiable(
      value.map(
        (key, item) => MapEntry(key.toString(), _freezeArguments(item)),
      ),
    );
  if (value is List)
    return List<Object?>.unmodifiable(value.map(_freezeArguments));
  return value;
}

/// A pending approval request for an MCP tool call.
class ToolApprovalRequest {
  final String toolCallId;
  final String toolName;
  final Map<String, dynamic> arguments;
  final String? conversationId;

  /// Identifies the exact capability being granted (e.g. `mcp:<tool>` or
  /// `shell:<cwd>\u0000<command>`). Null disables broader approval scopes.
  final String? grantKey;
  final Future<void> Function()? _persistGrant;
  final Completer<ToolApprovalResult> _completer;

  ToolApprovalRequest({
    required this.toolCallId,
    required this.toolName,
    required this.arguments,
    this.conversationId,
    this.grantKey,
    this._persistGrant,
    required this._completer,
  });

  Future<ToolApprovalResult> get future => _completer.future;

  /// Whether "allow for this conversation" can be offered.
  bool get canGrantConversation => grantKey != null && conversationId != null;

  /// Whether "always allow" can be offered.
  bool get canGrantAlways => _persistGrant != null;

  bool supports(ToolApprovalScope scope) => switch (scope) {
    ToolApprovalScope.once => true,
    ToolApprovalScope.conversation => canGrantConversation,
    ToolApprovalScope.always => canGrantAlways,
  };
}

/// Manages approval state for MCP tool calls that require user confirmation.
///
/// Flow:
/// 1. [requestApproval] is called from the tool handler when a tool needs approval.
///    It creates a [Completer], stores the request in [pendingRequests], and returns
///    the completer's future. The tool handler `await`s this future, blocking execution.
/// 2. The UI watches this service and shows approve/deny buttons.
/// 3. When the user taps approve/deny, [approve] or [deny] completes the completer,
///    unblocking the tool handler.
///
/// Storage is keyed by `(conversationId, toolCallId)` so two chats that share a
/// placeholder id such as `round-0:tool-1` keep independent Completers.
///
/// A request created with a [ToolApprovalRequest.grantKey] can also be approved
/// for the rest of its conversation; later requests with the same key in that
/// conversation then resolve immediately without showing a card.
class ToolApprovalService extends ChangeNotifier {
  final Map<_PendingKey, ToolApprovalRequest> _pending = {};
  final Map<String, Set<String>> _conversationGrants = {};
  int _unscopedSeq = 0;

  /// Whether [grantKey] was approved for the rest of [conversationId].
  bool hasConversationGrant(String conversationId, String grantKey) =>
      _conversationGrants[conversationId.trim()]?.contains(grantKey) ?? false;

  /// Revoke every conversation-scoped grant for [conversationId].
  void clearConversationGrants(String conversationId) {
    if (_conversationGrants.remove(conversationId.trim()) != null) {
      notifyListeners();
    }
  }

  /// Unmodifiable snapshot of pending approval requests.
  List<ToolApprovalRequest> get pendingRequests =>
      List<ToolApprovalRequest>.unmodifiable(_pending.values);

  /// Whether there are any pending approval requests.
  bool get hasPending => _pending.isNotEmpty;

  /// Check if a specific tool call is pending approval.
  ///
  /// When [conversationId] is omitted, any conversation with [toolCallId] counts.
  /// When it is provided, only that conversation (or an unscoped fail-safe) matches.
  bool isPending(String toolCallId, {String? conversationId}) {
    if (conversationId == null || conversationId.trim().isEmpty) {
      return _pending.values.any((req) => req.toolCallId == toolCallId);
    }
    return pendingFor(toolCallId: toolCallId, conversationId: conversationId) !=
        null;
  }

  /// Look up a pending request by conversation and tool-call id.
  ///
  /// Prefers an exact `(conversationId, toolCallId)` match. If none exists, an
  /// unscoped request (`conversationId == null`) with the same [toolCallId] is
  /// returned as a fail-safe. Another conversation's request is never returned.
  ToolApprovalRequest? pendingFor({
    required String toolCallId,
    String? conversationId,
  }) {
    if (toolCallId.isEmpty) return null;
    final scopedId = conversationId?.trim() ?? '';
    if (scopedId.isNotEmpty) {
      final scoped = _pending[_scopedKey(scopedId, toolCallId)];
      if (scoped != null) return scoped;
      return _findUnscoped(toolCallId);
    }
    final matches = _pending.values
        .where((req) => req.toolCallId == toolCallId)
        .toList();
    if (matches.length == 1) return matches.single;
    return _findUnscoped(toolCallId);
  }

  /// Request approval for a tool call.
  /// Returns a [Future] that completes when the user approves or denies.
  ///
  /// New requests should pass [conversationId]. A null conversation is stored
  /// under a unique unscoped key so two chats cannot overwrite each other.
  ///
  /// [grantKey] enables "allow for this conversation"; [persistGrant] enables
  /// "always allow" and is invoked once when the user picks that scope.
  Future<ToolApprovalResult> requestApproval({
    required String toolCallId,
    required String toolName,
    required Map<String, dynamic> arguments,
    String? conversationId,
    String? grantKey,
    Future<void> Function()? persistGrant,
  }) {
    final storedConversation = _storedConversationId(conversationId);
    if (storedConversation != null &&
        grantKey != null &&
        hasConversationGrant(storedConversation, grantKey)) {
      return Future.value(ToolApprovalResult.approved());
    }
    final key = _storageKey(conversationId, toolCallId);
    final existing = _pending[key];
    if (existing != null) {
      if (existing.toolName != toolName ||
          jsonEncode(existing.arguments) != jsonEncode(arguments)) {
        return Future.value(
          ToolApprovalResult.denied('approval_request_mismatch'),
        );
      }
      return existing.future;
    }
    final completer = Completer<ToolApprovalResult>();
    _pending[key] = ToolApprovalRequest(
      toolCallId: toolCallId,
      toolName: toolName,
      arguments:
          _freezeArguments(jsonDecode(jsonEncode(arguments)))
              as Map<String, dynamic>,
      conversationId: storedConversation,
      grantKey: grantKey,
      persistGrant: persistGrant,
      completer: completer,
    );
    notifyListeners();
    return completer.future;
  }

  /// Approve a pending tool call.
  ///
  /// A [scope] the request does not support falls back to [ToolApprovalScope.once].
  /// Broader scopes also release other pending calls with the same grant key in
  /// the same conversation.
  void approve(
    String toolCallId, {
    String? conversationId,
    ToolApprovalScope scope = ToolApprovalScope.once,
  }) {
    final req = _takePending(
      toolCallId: toolCallId,
      conversationId: conversationId,
    );
    if (req != null && !req._completer.isCompleted) {
      req._completer.complete(ToolApprovalResult.approved());
    }
    if (req != null && scope != ToolApprovalScope.once && req.supports(scope)) {
      if (req.canGrantConversation) {
        _grantConversation(req.conversationId!, req.grantKey!);
      }
      if (scope == ToolApprovalScope.always) {
        unawaited(_persist(req));
      }
    }
    notifyListeners();
  }

  void _grantConversation(String conversationId, String grantKey) {
    (_conversationGrants[conversationId] ??= <String>{}).add(grantKey);
    final released = _pending.entries
        .where(
          (entry) =>
              entry.value.conversationId == conversationId &&
              entry.value.grantKey == grantKey,
        )
        .toList();
    for (final entry in released) {
      _pending.remove(entry.key);
      if (!entry.value._completer.isCompleted) {
        entry.value._completer.complete(ToolApprovalResult.approved());
      }
    }
  }

  Future<void> _persist(ToolApprovalRequest req) async {
    try {
      await req._persistGrant!();
    } catch (error, stack) {
      // The current call is already approved; only the saved grant failed.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kelivo tool approval',
          context: ErrorDescription('while saving an always-allow grant'),
        ),
      );
    }
  }

  /// Deny a pending tool call with an optional reason.
  void deny(String toolCallId, {String? reason, String? conversationId}) {
    final req = _takePending(
      toolCallId: toolCallId,
      conversationId: conversationId,
    );
    if (req != null && !req._completer.isCompleted) {
      req._completer.complete(ToolApprovalResult.denied(reason));
    }
    notifyListeners();
  }

  /// Cancel all pending approvals (e.g., when streaming is cancelled).
  void cancelAll() {
    for (final req in _pending.values) {
      if (!req._completer.isCompleted) {
        req._completer.complete(ToolApprovalResult.denied('cancelled'));
      }
    }
    _pending.clear();
    notifyListeners();
  }

  /// Cancel pending approvals that belong to [conversationId]. Requests with
  /// no recorded conversation are cancelled too (fail-safe against leaking a
  /// blocked tool handler), but approvals owned by other conversations keep
  /// waiting so cancelling one conversation cannot break another's stream.
  void cancelForConversation(String conversationId) {
    final toCancel = _pending.values
        .where(
          (req) =>
              req.conversationId == null ||
              req.conversationId == conversationId,
        )
        .toList();
    if (toCancel.isEmpty) return;
    for (final req in toCancel) {
      _pending.removeWhere((_, value) => identical(value, req));
      if (!req._completer.isCompleted) {
        req._completer.complete(ToolApprovalResult.denied('cancelled'));
      }
    }
    notifyListeners();
  }

  ToolApprovalRequest? _takePending({
    required String toolCallId,
    String? conversationId,
  }) {
    final scopedId = conversationId?.trim() ?? '';
    if (scopedId.isNotEmpty) {
      final scoped = _pending.remove(_scopedKey(scopedId, toolCallId));
      if (scoped != null) return scoped;
      return _removeUnscoped(toolCallId);
    }
    final matches = _pending.entries
        .where((entry) => entry.value.toolCallId == toolCallId)
        .toList();
    if (matches.length == 1) {
      _pending.remove(matches.single.key);
      return matches.single.value;
    }
    return _removeUnscoped(toolCallId);
  }

  ToolApprovalRequest? _findUnscoped(String toolCallId) {
    final matches = _pending.values
        .where(
          (req) =>
              req.toolCallId == toolCallId &&
              (req.conversationId == null || req.conversationId!.isEmpty),
        )
        .toList();
    if (matches.length == 1) return matches.single;
    return null;
  }

  ToolApprovalRequest? _removeUnscoped(String toolCallId) {
    final matches = _pending.entries
        .where(
          (entry) =>
              entry.value.toolCallId == toolCallId &&
              (entry.value.conversationId == null ||
                  entry.value.conversationId!.isEmpty),
        )
        .toList();
    if (matches.length != 1) return null;
    _pending.remove(matches.single.key);
    return matches.single.value;
  }

  _PendingKey _storageKey(String? conversationId, String toolCallId) {
    final scopedId = conversationId?.trim() ?? '';
    if (scopedId.isNotEmpty) {
      return _scopedKey(scopedId, toolCallId);
    }
    return (scope: 'unscoped:${_unscopedSeq++}', toolCallId: toolCallId);
  }

  static _PendingKey _scopedKey(String conversationId, String toolCallId) {
    return (scope: conversationId, toolCallId: toolCallId);
  }

  static String? _storedConversationId(String? conversationId) {
    final trimmed = conversationId?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}
