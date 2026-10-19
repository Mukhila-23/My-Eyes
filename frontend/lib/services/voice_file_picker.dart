import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Outcome of a voice-driven file pick.
class PickedFileResult {
  const PickedFileResult({this.bytes, this.fileName});

  final Uint8List? bytes;
  final String? fileName;

  bool get picked => bytes != null && bytes!.isNotEmpty;
}

/// SAF-safe helper for the "tell me the file name" voice flow.
///
/// Opening a file by an arbitrary spoken substring would require unrestricted
/// filesystem enumeration, which this app deliberately avoids. Instead we use
/// the Android system file picker (Storage Access Framework), which only ever
/// exposes files the user grants access to — never an unrestricted scan.
///
/// The spoken name is used to:
///  - set a helpful picker title (e.g. "Choose your medicine file"), and
///  - confirm the picked file (verified as a low-stress confirmation, not a
///    hard filter), so a "medicine" request flows naturally.
class VoiceFilePicker {
  VoiceFilePicker._();

  static final VoiceFilePicker instance = VoiceFilePicker._();

  /// Opens the system image picker and returns the picked file's bytes.
  ///
  /// [spokenName] is the lower-cased substring the user said ("medicine").
  /// Returns null (with [PickedFileResult.picked] == false) if cancelled.
  Future<PickedFileResult> pickImageForName(String spokenName) async {
    final title = _titleFor(spokenName);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
        dialogTitle: title,
      );

      if (result == null || result.files.isEmpty) {
        return const PickedFileResult();
      }

      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        return const PickedFileResult();
      }

      return PickedFileResult(
        bytes: bytes,
        fileName: file.name,
      );
    } catch (_) {
      // Never let a picker failure crash a blind user's flow.
      return const PickedFileResult();
    }
  }

  /// A friendly, readable picker title derived from the spoken name.
  String _titleFor(String spokenName) {
    final clean = spokenName
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) return 'Choose an image';
    final title = clean[0].toUpperCase() + clean.substring(1);
    return 'Choose your $title image';
  }
}
