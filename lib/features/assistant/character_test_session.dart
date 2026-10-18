import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models/assistant.dart';

/// Coordinates the "test chat" flow for an assistant (character).
///
/// Settings UI calls [start]; the home page listens to [requests], opens a
/// new conversation with that assistant in the main chat, and then docks the
/// assistant settings next to the chat via [dockedAssistantId].
class CharacterTestSession {
  CharacterTestSession._();

  static final CharacterTestSession instance = CharacterTestSession._();

  final StreamController<String> _requests =
      StreamController<String>.broadcast();

  Stream<String> get requests => _requests.stream;

  /// Assistant whose settings are docked beside the chat, or null when no
  /// test session is active.
  final ValueNotifier<String?> dockedAssistantId = ValueNotifier<String?>(
    null,
  );

  /// Whether memory (injection, memory tools, auto-organize, past-chat recall
  /// and summaries) stays on for the test conversation. Off by default so
  /// test runs do not pollute the character's long-term memory.
  final ValueNotifier<bool> memoryEnabled = ValueNotifier<bool>(false);

  String? _conversationId;

  void start(String assistantId) {
    _requests.add(assistantId);
  }

  void attach({required String assistantId, required String? conversationId}) {
    _conversationId = conversationId;
    dockedAssistantId.value = assistantId;
  }

  void close() {
    _conversationId = null;
    dockedAssistantId.value = null;
  }

  bool blocksMemory(String? conversationId) =>
      !memoryEnabled.value &&
      conversationId != null &&
      conversationId == _conversationId;

  /// Returns [assistant] with every memory feature disabled when
  /// [conversationId] is the active test conversation and memory is off.
  Assistant? applyMemoryOverride(String? conversationId, Assistant? assistant) {
    if (assistant == null || !blocksMemory(conversationId)) return assistant;
    return assistant.copyWith(
      enableMemory: false,
      autoOrganizeMemory: false,
      allowPastConversationRecall: false,
      generateConversationSummary: false,
    );
  }
}
