import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/storage/secure_storage.dart';
import 'auth_service.dart';

/// Outcome of an AI Help request.
class AIChatResult {
  const AIChatResult({
    required this.success,
    this.answer = '',
    this.conversationId,
    this.error = '',
    this.errorCode = '',
  });

  final bool success;

  /// The AI answer text. Same value as [answer].
  final String answer;
  final int? conversationId;

  /// A calm, spoken-friendly error message when [success] is false.
  final String error;

  /// Machine-readable backend error code, for logs/debugging only.
  final String errorCode;
}

/// Talk to the AI Help endpoint on the My Eyes FastAPI backend.
///
/// The Gemini API key NEVER lives on the device; it is held only on the
/// server. This client authenticates with the existing JWT and forwards the
/// user's exact recognized question. The backend calls the Gemini API (Free
/// Tier) and returns the spoken-friendly answer.
class AIService {
  AIService._();

  /// Endpoint on the backend. `question` is the exact recognized text; the
  /// backend forwards it to Gemini.
  static const String endpoint = '/ai-help';

  /// The backend gives up on Gemini after 45s, so wait a little longer than
  /// that and no longer - the user must not sit in "Thinking..." forever.
  static const Duration _timeout = Duration(seconds: 60);

  /// Shared client so an in-flight AI request can be aborted when the user
  /// presses Back (see [cancelPending]).
  static final http.Client _client = http.Client();

  /// True while a request is in flight. Guards against the recogniser firing
  /// a second question while the first one is still being answered.
  ///
  /// This is a request TOKEN, not a bool. [cancelPending] has to abandon the
  /// guard immediately so the user can ask something else right away, but the
  /// abandoned request is still draining in the background and its `finally`
  /// block runs later. With a bool that late `finally` would clear the guard
  /// belonging to the NEXT request, letting two answers race and the later
  /// one overwrite the newer question's answer. Comparing tokens means a
  /// superseded request can only ever clear its own guard.
  static int _tokenCounter = 0;
  static int _activeToken = 0;

  static bool get isRequestInFlight => _activeToken != 0;

  /// Sends a question to the AI assistant. Pass an existing
  /// [conversationId] to continue the current conversation (so follow-up
  /// questions like "what companies does he own?" keep their context), or
  /// omit it to start a new conversation.
  static Future<AIChatResult> chat({
    required String question,
    int? conversationId,
  }) async {
    final text = question.trim();

    if (text.isEmpty) {
      return const AIChatResult(
        success: false,
        errorCode: 'EMPTY_QUESTION',
        error: "I didn't catch that. Please ask a question.",
      );
    }

    // Never stack requests: a second tap/utterance while one is running is
    // dropped instead of racing.
    if (_activeToken != 0) {
      debugPrint('[MY EYES] AI: request already in flight, dropping duplicate');
      return const AIChatResult(
        success: false,
        errorCode: 'REQUEST_IN_FLIGHT',
        error: '',
      );
    }

    final token = await SecureStorage.readAccessToken();
    if (token == null || token.isEmpty) {
      return const AIChatResult(
        success: false,
        errorCode: 'NO_SESSION',
        error: 'Your session has expired. Please go back and sign in again.',
      );
    }

    debugPrint('[MY EYES] AI REQUEST -> $endpoint : "$text" '
        '(conversation=$conversationId)');

    // `token` is already the JWT above; this is the in-flight request guard.
    final requestToken = ++_tokenCounter;
    _activeToken = requestToken;
    try {
      final response = await _client
          .post(
            Uri.parse('${AuthService.baseUrl}$endpoint'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'question': text,
              'conversation_id': ?conversationId,
            }),
          )
          .timeout(_timeout);

      debugPrint('[MY EYES] AI HTTP STATUS: ${response.statusCode}');

      final body = _decodeBody(response.body);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = _errorCode(body);
        final hint = _errorHint(body);
        debugPrint('[MY EYES] AI ERROR [$code] $hint');
        return AIChatResult(
          success: false,
          errorCode: code,
          error: _messageFor(body, response.statusCode),
        );
      }

      // The backend returns {"success": true, "answer": "...", "response":
      // "...", "conversation_id": n}. Accept `answer` first, `response` as
      // a fallback.
      final answer =
          (body['answer'] ?? body['response'])?.toString().trim() ?? '';
      final conversation = _toInt(body['conversation_id']);

      if (answer.isEmpty) {
        return const AIChatResult(
          success: false,
          errorCode: 'EMPTY_ANSWER',
          error: 'The AI assistant returned an empty answer. Please try again.',
        );
      }

      debugPrint('[MY EYES] AI ANSWER (${answer.length} chars), '
          'conversation=$conversation');
      return AIChatResult(
        success: true,
        answer: answer,
        conversationId: conversation,
      );
    } on TimeoutException {
      return const AIChatResult(
        success: false,
        errorCode: 'TIMEOUT',
        error: 'AI Help took too long to respond. Please try again.',
      );
    } on SocketException catch (e) {
      debugPrint('[MY EYES] AI NETWORK ERROR: ${e.message}');
      return const AIChatResult(
        success: false,
        errorCode: 'NETWORK',
        error: "I can't reach the server. Please check your internet "
            'connection.',
      );
    } on http.ClientException catch (e) {
      debugPrint('[MY EYES] AI CLIENT ERROR: ${e.message}');
      return const AIChatResult(
        success: false,
        errorCode: 'NETWORK',
        error: "I can't reach the server. Please check your internet "
            'connection.',
      );
    } catch (e) {
      debugPrint('[MY EYES] AI UNEXPECTED ERROR: $e');
      return const AIChatResult(
        success: false,
        errorCode: 'UNKNOWN',
        error: 'AI Help is temporarily unavailable. Please try again.',
      );
    } finally {
      // Only release the guard if it is still ours: [cancelPending] may have
      // handed it to a newer request while this one was finishing.
      if (_activeToken == requestToken) _activeToken = 0;
    }
  }

  /// Clears the current Help conversation ("New chat") so follow-up
  /// questions start from a clean context.
  static Future<bool> clear({required int conversationId}) async {
    final token = await SecureStorage.readAccessToken();
    if (token == null || token.isEmpty) return false;

    try {
      final response = await _client
          .delete(
            Uri.parse('${AuthService.baseUrl}$endpoint/$conversationId'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
      debugPrint('[MY EYES] AI CLEAR $conversationId -> '
          '${response.statusCode}');
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Aborts an in-flight AI request. Called when the user leaves Help so a
  /// late response can never speak over the dashboard.
  ///
  /// The HTTP call itself cannot be un-sent, so the guard is simply released
  /// for the next question. The token check in `chat`'s `finally` stops that
  /// abandoned request from later clearing a newer request's guard.
  static void cancelPending() {
    _activeToken = 0;
  }

  // ============================================================
  // PARSING HELPERS
  // ============================================================

  static Map<String, dynamic> _decodeBody(String raw) {
    if (raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Fall through to an empty map; the status check handles it.
    }
    return <String, dynamic>{};
  }

  /// Backend failure envelope: {"success": false, "error": {code, message,
  /// hint}}. The hint is developer-facing and never read aloud.
  static String _messageFor(Map<String, dynamic> body, int statusCode) {
    final error = body['error'];
    if (error is Map<String, dynamic>) {
      final message = error['message'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
    }

    switch (statusCode) {
      case 401:
        return 'Your session has expired. Please sign in again.';
      case 403:
        return 'You are not allowed to do that.';
      case 404:
        return 'I could not find that. Please try again.';
      case 422:
        return "I couldn't process that question. Please try again.";
      case 429:
        return 'Too many requests right now. Please wait a moment.';
      case 502:
      case 503:
      case 504:
        return 'AI Help is temporarily unavailable. Please try again.';
      default:
        return statusCode >= 500
            ? 'Something went wrong on the server. Please try again.'
            : "I couldn't complete that request. Please try again.";
    }
  }

  static String _errorCode(Map<String, dynamic> body) {
    final error = body['error'];
    if (error is Map<String, dynamic>) {
      final code = error['code'];
      if (code is String && code.isNotEmpty) return code;
    }
    return 'HTTP_ERROR';
  }

  static String _errorHint(Map<String, dynamic> body) {
    final error = body['error'];
    if (error is Map<String, dynamic>) {
      final hint = error['hint'];
      if (hint is String && hint.isNotEmpty) return hint;
    }
    return '';
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}