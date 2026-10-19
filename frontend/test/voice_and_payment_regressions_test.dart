import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/vision_mode.dart';
import 'package:frontend/services/app_instructions.dart';
import 'package:frontend/services/companion.dart';
import 'package:frontend/services/upi_payment_codec.dart';
import 'package:frontend/services/upi_qr_parser.dart';
import 'package:frontend/services/voice_command_service.dart';

/// Chunked TTS delivery.
///
/// The dashboard guide is handed to the TTS engine as a sequence of short
/// utterances instead of one very long call. These tests pin the two things
/// that matter: no chunk ever exceeds the engine's safe size, and the
/// reassembled text loses nothing.
void main() {
  group('VoiceCommandService.chunkForSpeech', () {
    test('returns nothing for empty text', () {
      expect(VoiceCommandService.chunkForSpeech(''), isEmpty);
      expect(VoiceCommandService.chunkForSpeech('   '), isEmpty);
    });

    test('keeps short text as a single chunk, unchanged', () {
      const text = 'Say camera, or say choose a file.';
      expect(VoiceCommandService.chunkForSpeech(text), [text]);
    });

    test('splits a long script into chunks within the cap', () {
      final script = AppInstructions.dashboardInstructions(
        companion: Companions.maya,
        sosConfigured: false,
      );

      // The real script must actually be long enough to need splitting, or this
      // test would pass without proving anything.
      expect(script.length, greaterThan(2000));

      final chunks = VoiceCommandService.chunkForSpeech(script);

      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(
          chunk.length,
          lessThanOrEqualTo(VoiceCommandService.maxSpeechChunkChars),
          reason: 'chunk too long: ${chunk.length} chars',
        );
        expect(chunk.trim(), isNotEmpty);
      }
    });

    test('loses no words when a script is split and rejoined', () {
      final script = AppInstructions.dashboardInstructions(
        companion: Companions.alex,
        sosConfigured: true,
      );

      final rejoined = VoiceCommandService.chunkForSpeech(script)
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final original =
          script.replaceAll(RegExp(r'\s+'), ' ').trim();

      expect(rejoined, original);
    });

    test('hard-splits a single sentence longer than the cap', () {
      // One sentence with no terminator until the very end, so sentence-based
      // splitting cannot help.
      final huge = List.filled(200, 'word').join(' ');

      final chunks = VoiceCommandService.chunkForSpeech(huge);

      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(
          chunk.length,
          lessThanOrEqualTo(VoiceCommandService.maxSpeechChunkChars),
        );
      }
      expect(chunks.join(' ').split(' '), hasLength(200));
    });

    test('prefers sentence boundaries', () {
      final text = List.generate(
        60,
        (i) => 'Sentence number $i ends here.',
      ).join(' ');

      final chunks = VoiceCommandService.chunkForSpeech(text);

      // Every chunk except possibly the last should end on a full stop.
      for (final chunk in chunks.take(chunks.length - 1)) {
        expect(chunk.endsWith('.'), isTrue, reason: 'cut mid-sentence: $chunk');
      }
    });
  });

  group('AppInstructions.historyAfterResultSpoken', () {
    test('names the history command and the module', () {
      final spoken = AppInstructions.historyAfterResultSpoken(
        VisionMode.currency,
      );

      expect(spoken, contains('history'));
      expect(spoken.toLowerCase(), contains('currency'));
    });
  });

  group('UPI payment codec', () {
    test('builds a canonical upi://pay URI', () {
      final uri = Uri.parse(
        buildPaymentUri(
          vpa: 'merchant@okaxis',
          payeeName: 'Corner Store',
          amount: 250.5,
          note: 'My Eyes payment',
          transactionRef: 'MYE123',
        ),
      );

      expect(uri.scheme, 'upi');
      expect(uri.host, 'pay');
      expect(uri.queryParameters['pa'], 'merchant@okaxis');
      expect(uri.queryParameters['pn'], 'Corner Store');
      expect(uri.queryParameters['am'], '250.50');
      expect(uri.queryParameters['cu'], 'INR');
      expect(uri.queryParameters['tr'], 'MYE123');
    });

    test('never reports success without an explicit success response', () {
      expect(
        parsePaymentStatus(resultOk: true, resultCode: 0),
        UpiLaunchStatus.unknown,
      );
      expect(
        parsePaymentStatus(
          response: 'upi://pay?tr=1&status=success&Amount=100',
        ),
        UpiLaunchStatus.success,
      );
      expect(
        parsePaymentStatus(response: 'upi://pay?tr=1&status=failure'),
        UpiLaunchStatus.failed,
      );
    });
  });

  group('UpiQrParser', () {
    test('rejects a non-UPI string', () {
      expect(UpiQrParser.parse('just some text'), isNull);
      expect(UpiQrParser.parse(null), isNull);
    });

    test('reads a dynamic UPI QR', () {
      final details = UpiQrParser.parse(
        'upi://pay?pa=shop@upi&pn=Shop&am=100.00&cu=INR&tr=abc',
      );

      expect(details, isNotNull);
      expect(details!.payeeVpa, 'shop@upi');
      expect(details.amount, 100.0);
      expect(details.isDynamic, isTrue);
    });

    test('reads a static UPI QR', () {
      final details = UpiQrParser.parse('upi://pay?pa=shop@upi&pn=Shop');

      expect(details, isNotNull);
      expect(details!.hasAmount, isFalse);
      expect(details.isDynamic, isFalse);
    });
  });
}