/// Pure-Dart splitting of a long spoken script into TTS-sized utterances.
///
/// Deliberately dependency-free, in the same style as
/// [upi_payment_codec.dart], so the chunking can be exercised directly under
/// the Dart VM without the Flutter engine.
///
/// Why this exists: the spoken My Eyes guide is several thousand characters.
/// Handing that to Android's speech engine as ONE utterance is unreliable - the
/// engine starts, then the caller's single-utterance timeout fires and the
/// guide is cut off mid-sentence. That was the real cause of the Instructions
/// button appearing to do nothing. Splitting the same text into
/// sentence-aligned pieces gives each one its own completion callback, so the
/// whole script is delivered reliably.
library;

/// Maximum characters handed to the TTS engine in one call.
///
/// Comfortably below the point where Android's speech engine starts dropping
/// or truncating text, while still being long enough that a normal sentence is
/// never chopped awkwardly.
const int maxSpeechChunkChars = 400;

/// Splits [text] into chunks of at most [maxChars] characters.
///
/// Sentence boundaries are preferred so the delivered audio sounds like
/// natural pauses. A single sentence longer than the cap is split on word
/// boundaries, so no chunk is ever oversized. No word is dropped or duplicated:
/// the chunks joined with a single space reproduce the whitespace-normalised
/// input.
List<String> chunkForSpeech(String text, {int maxChars = maxSpeechChunkChars}) {
  final normalized = text.trim();
  if (normalized.isEmpty) return const [];

  if (normalized.length <= maxChars) return [normalized];

  final chunks = <String>[];

  // Build up a chunk from whole sentences.
  var current = StringBuffer();

  for (final sentence in _splitSentences(normalized)) {
    if (sentence.length > maxChars) {
      // Flush what we have, then hard-split the oversized sentence.
      final pending = current.toString().trim();
      if (pending.isNotEmpty) chunks.add(pending);
      current = StringBuffer();
      chunks.addAll(_splitOversized(sentence, maxChars));
      continue;
    }

    final candidate =
        current.isEmpty ? sentence : '${current.toString()} $sentence';
    if (candidate.length > maxChars) {
      final pending = current.toString().trim();
      if (pending.isNotEmpty) chunks.add(pending);
      current = StringBuffer(sentence);
    } else {
      current = StringBuffer(candidate);
    }
  }

  final tail = current.toString().trim();
  if (tail.isNotEmpty) chunks.add(tail);

  return chunks;
}

/// Splits into sentences, keeping the terminator attached to each one.
///
/// Newline-separated lines from a multi-line script are also treated as
/// boundaries, so the chunker does not merge two unrelated paragraphs when a
/// line happens to have no full stop.
List<String> _splitSentences(String text) {
  final sentences = <String>[];
  final buffer = StringBuffer();

  for (final line in text.split('\n')) {
    final trimmedLine = line.trim();
    if (trimmedLine.isEmpty) continue;

    for (final word in trimmedLine.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      buffer.write(word);
      buffer.write(' ');

      if (_endsSentence(word)) {
        sentences.add(buffer.toString().trim());
        buffer.clear();
      }
    }

    // Line end is a boundary even without a terminator.
    final pending = buffer.toString().trim();
    if (pending.isNotEmpty) {
      sentences.add(pending);
      buffer.clear();
    }
  }

  return sentences;
}

bool _endsSentence(String word) =>
    word.endsWith('.') ||
    word.endsWith('!') ||
    word.endsWith('?') ||
    word.endsWith(';');

/// Last-resort split of one sentence longer than [maxChars].
///
/// Breaks on word boundaries only. A single word longer than the cap is itself
/// split on character boundaries, so no chunk can ever overflow.
List<String> _splitOversized(String sentence, int maxChars) {
  final parts = <String>[];
  var buffer = StringBuffer();

  void flush() {
    final value = buffer.toString().trim();
    if (value.isNotEmpty) parts.add(value);
    buffer = StringBuffer();
  }

  for (final word in sentence.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;

    if (buffer.isNotEmpty &&
        '${buffer.toString()} $word'.length > maxChars) {
      flush();
    }

    // A single oversized word (a long URL, an unspaced blob) still has to be
    // broken up, otherwise it would produce an over-cap chunk.
    if (word.length > maxChars) {
      flush();
      for (var i = 0; i < word.length; i += maxChars) {
        final end = (i + maxChars).clamp(0, word.length);
        parts.add(word.substring(i, end));
      }
      continue;
    }

    buffer.write(word);
    buffer.write(' ');
  }

  flush();
  return parts;
}