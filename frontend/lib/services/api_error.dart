/// Converts an HTTP status code + (structured) backend error body into a
/// short, calm, non-technical message suitable for speech to a blind user.
///
/// The backend now returns `{success:false, error:{code, message}}` for all
/// failures. This helper extracts a safe, readable line and falls back to a
/// clear default per status code so the user never hears raw JSON / Pydantic
/// internals like "Unprocessable Content".
library;

String friendlyApiMessage(int statusCode, dynamic body, {String fallback = ''}) {
  // Honour the structured envelope my backend now returns.
  final error = _extractStructuredMessage(body);
  if (error != null && error.isNotEmpty) {
    return error;
  }

  switch (statusCode) {
    case 400:
      return 'The request was not valid. Please check the details and try again.';
    case 401:
      return 'Your session has expired. Please sign in again.';
    case 403:
      return 'You are not allowed to do that.';
    case 404:
      return 'I could not find that. Please try again.';
    case 422:
      return "I couldn't process that request. Please try again.";
    case 429:
      return 'Too many requests right now. Please wait a moment.';
    default:
      if (statusCode >= 500) {
        return 'Something went wrong on the server. Please try again.';
      }
      return fallback.isEmpty
          ? "I couldn't complete that request. Please try again."
          : fallback;
  }
}

/// Pulls `error.message` from the `{success:false,error:{code,message}}`
/// envelope if present.
String? _extractStructuredMessage(dynamic body) {
  if (body is Map<String, dynamic>) {
    final error = body['error'];
    if (error is Map<String, dynamic>) {
      final message = error['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
    }
  }
  return null;
}
