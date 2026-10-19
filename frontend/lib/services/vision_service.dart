import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/storage/secure_storage.dart';
import '../core/vision_mode.dart';
import 'api_error.dart';
import 'auth_service.dart';

class VisionResult {
  final bool success;
  final String message;
  final String? detectedText;

  const VisionResult({
    required this.success,
    required this.message,
    this.detectedText,
  });
}

/// Sends a captured image to the My Eyes FastAPI backend and turns
/// the raw JSON answer into one friendly sentence that can be
/// spoken aloud to a blind user.
class VisionService {
  VisionService._();

  static const Duration _timeout = Duration(seconds: 90);

  // ============================================================
  // PROCESS IMAGE
  // ============================================================

  static Future<VisionResult> processImage({
    required VisionMode mode,
    required Uint8List imageBytes,
    String fileName = 'image.jpg',
    String? target,
  }) async {
    final endpoint = _endpointFor(mode);

    if (endpoint == null) {
      return const VisionResult(
        success: false,
        message: 'This module is not connected to the server yet.',
      );
    }

    final token = await SecureStorage.readAccessToken();

    if (token == null || token.isEmpty) {
      return const VisionResult(
        success: false,
        message:
            'Your session has expired. Please go back and log in again.',
      );
    }

    debugPrint('[API] request started: POST $endpoint '
        'mode=${mode.name} file=$fileName bytes=${imageBytes.length}');

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${AuthService.baseUrl}$endpoint'),
      );

      request.headers['Authorization'] = 'Bearer $token';
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: fileName,
        ),
      );

      // `send()` only waits for the connection/response headers.  The old
      // code left a screen spinning forever when a server accepted the
      // upload but never completed its response body.  Time-bound both
      // phases so every request has a terminal outcome.
      final streamed = await request.send().timeout(_timeout);
      final response = await http.Response.fromStream(streamed).timeout(_timeout);

      debugPrint('[API] request completed: $endpoint');
      debugPrint('[API] status: ${response.statusCode}');

      final body = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;

      debugPrint('[API] response: ${response.body}');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return VisionResult(
          success: false,
          message: friendlyApiMessage(
            response.statusCode,
            body,
            fallback: 'The server could not process this image. Please try again.',
          ),
        );
      }

      return _interpretResponse(mode, body, target);
    } on TimeoutException {
      debugPrint('[API] timeout: $endpoint');
      return VisionResult(success: false, message: _timeoutMessage(mode));
    } on SocketException {
      debugPrint('[API] connection failed: $endpoint');
      return VisionResult(success: false, message: _networkErrorMessage(mode));
    } on http.ClientException {
      debugPrint('[API] client error: $endpoint');
      return VisionResult(success: false, message: _networkErrorMessage(mode));
    } catch (error) {
      debugPrint('[API] unexpected error for $endpoint: $error');
      return VisionResult(success: false, message: _unexpectedErrorMessage(mode));
    }
  }

  // ============================================================
  // FAILURE MESSAGES (SPOKEN TO A BLIND USER)
  // ============================================================

  /// A timeout must still end the operation on the screen; the sentence
  /// differs per module so the user hears what did not finish.
  static String _timeoutMessage(VisionMode mode) {
    if (mode == VisionMode.currency) {
      return "I couldn't identify the currency in time. Please try again.";
    }
    return 'The analysis took too long. Please try again with better lighting.';
  }

  static String _networkErrorMessage(VisionMode mode) {
    if (mode == VisionMode.currency) {
      return "Currency detection needs the My Eyes server. Please check your "
          'internet connection and try again.';
    }
    return 'Cannot reach the My Eyes server. Please check your internet connection.';
  }

  static String _unexpectedErrorMessage(VisionMode mode) {
    if (mode == VisionMode.currency) {
      return 'Currency detection is temporarily unavailable. Please try again.';
    }
    return 'Something went wrong while analyzing the image.';
  }

  // ============================================================
  // ENDPOINT MAP (MATCHES THE FASTAPI ROUTERS)
  // ============================================================

  static String? _endpointFor(VisionMode mode) {
    switch (mode) {
      case VisionMode.scanObject:
      case VisionMode.objectFinder:
        return '/objects/detect';

      case VisionMode.readText:
        return '/ocr/scan';

      case VisionMode.medicine:
        return '/medicine/scan';

      case VisionMode.product:
        return '/product/scan';

      case VisionMode.currency:
        return '/currency/scan';

      case VisionMode.scene:
        return '/scene/describe';
    }
  }

  // ============================================================
  // RESPONSE INTERPRETERS (EXACT BACKEND FIELD NAMES)
  // ============================================================

  static VisionResult _interpretResponse(
    VisionMode mode,
    Map<String, dynamic> body,
    String? target,
  ) {
    // A 200 response can still mean that OCR/model inference found nothing.
    // Do not announce it as a successful detection merely because HTTP did.
    if (body['success'] == false) {
      final message = body['display_text']?.toString().trim() ??
          body['message']?.toString().trim() ??
          'I could not process this image. Please try again.';
      return VisionResult(success: false, message: message);
    }

    switch (mode) {
      case VisionMode.scanObject:
        return _objectResult(body);

      case VisionMode.objectFinder:
        return _objectFinderResult(body, target);

      case VisionMode.readText:
        return _textResult(body);

      case VisionMode.medicine:
        return _medicineResult(body);

      case VisionMode.product:
        return _productResult(body);

      case VisionMode.currency:
        return _currencyResult(body);

      case VisionMode.scene:
        return _sceneResult(body);
    }
  }

  /// /objects/detect -> {"objects": [{"object": str, "confidence": f}]}
  static VisionResult _objectResult(Map<String, dynamic> body) {
    final names = _extractObjectNames(body);

    if (names.isEmpty) {
      return const VisionResult(
        success: true,
        message:
            'I could not identify any objects. Try moving closer and scanning again.',
      );
    }

    return VisionResult(
      success: true,
      message: 'I can see ${_joinNames(names)}.',
      detectedText: names.join(', '),
    );
  }

  /// Object Finder compares the detected objects with the target
  /// the user asked for, e.g. "find my phone".
  static VisionResult _objectFinderResult(
    Map<String, dynamic> body,
    String? target,
  ) {
    final names = _extractObjectNames(body);

    if (target != null && target.isNotEmpty) {
      final match = names.firstWhere(
        (name) => name.contains(target) || target.contains(name),
        orElse: () => '',
      );

      if (match.isNotEmpty) {
        return VisionResult(
          success: true,
          message: 'Yes! I found your $match. It is in front of you.',
          detectedText: match,
        );
      }

      if (names.isEmpty) {
        return VisionResult(
          success: true,
          message:
              'I could not see any objects. Move the camera slowly around and try again.',
        );
      }

      return VisionResult(
        success: true,
        message:
            'I could not find your $target here. I can only see ${_joinNames(names)}.',
        detectedText: names.join(', '),
      );
    }

    return _objectResult(body);
  }

  /// /ocr/scan -> {"extracted_text": str}
  static VisionResult _textResult(Map<String, dynamic> body) {
    final text = body['extracted_text']?.toString().trim() ?? '';

    if (text.isEmpty) {
      return const VisionResult(
        success: true,
        message:
            'I could not find any readable text. Hold the document steady and try again.',
      );
    }

    return VisionResult(
      success: true,
      message: text,
      detectedText: text,
    );
  }

  /// /medicine/scan -> {"medicine_name": str, "full_text": str}
  static VisionResult _medicineResult(Map<String, dynamic> body) {
    final name = body['medicine_name']?.toString().trim() ?? '';
    var details = body['full_text']?.toString().trim() ?? '';

    if (details == name) details = '';

    if (name.isEmpty && details.isEmpty) {
      return const VisionResult(
        success: true,
        message:
            'I could not read this medicine. Please place it on a plain surface and scan again.',
      );
    }

    final message = details.isEmpty
        ? 'The medicine appears to be $name.'
        : 'The medicine is $name. Details: $details';

    return VisionResult(
      success: true,
      message: message,
      detectedText: name,
    );
  }

  /// /product/scan ->
  /// {"product_name", "brand", "net_quantity", "mrp",
  ///  "expiry_date", "ingredients": [...], ...}
  static VisionResult _productResult(Map<String, dynamic> body) {
    final parts = <String>[];

    final productName = body['product_name']?.toString().trim() ?? '';
    final brand = body['brand']?.toString().trim() ?? '';
    final mrp = body['mrp']?.toString().trim() ?? '';
    final quantity = body['net_quantity']?.toString().trim() ?? '';
    final expiry = body['expiry_date']?.toString().trim() ?? '';

    if (productName.isNotEmpty) parts.add('Product: $productName');
    if (brand.isNotEmpty) parts.add('Brand: $brand');
    if (mrp.isNotEmpty) parts.add('Maximum retail price $mrp');
    if (quantity.isNotEmpty) parts.add('Net quantity $quantity');
    if (expiry.isNotEmpty) parts.add('Expiry date $expiry');

    if (parts.isEmpty) {
      return const VisionResult(
        success: true,
        message:
            'I could not read this product. Turn the package towards the camera and try again.',
      );
    }

    return VisionResult(
      success: true,
      message: '${parts.join('. ')}.',
      detectedText: parts.join(', '),
    );
  }

  /// /currency/scan -> {"success", "currency", "denomination",
  /// "display_text", "confidence"}.  Keep accepting the old `currency`
  /// field so upgrading the app and backend independently remains safe.
  static VisionResult _currencyResult(Map<String, dynamic> body) {
    final currency = body['currency']?.toString().trim() ?? '';
    final displayText = body['display_text']?.toString().trim() ?? '';
    final confidence = _toDouble(body['confidence']);

    if (currency.isEmpty ||
        currency.toLowerCase() == 'unknown' ||
        currency.toLowerCase() == 'none' ||
        confidence <= 0) {
      return VisionResult(
        success: false,
        message: displayText.isEmpty
            ? 'I could not identify the currency. Please place one currency note clearly in front of the camera and try again.'
            : displayText,
      );
    }

    return VisionResult(
      success: true,
      message: displayText.isEmpty ? 'This is a $currency note.' : displayText,
      detectedText: currency,
    );
  }

  /// /scene/describe -> {"description": str}
  static VisionResult _sceneResult(Map<String, dynamic> body) {
    final description = body['description']?.toString().trim() ?? '';

    if (description.isEmpty) {
      return const VisionResult(
        success: true,
        message: 'I could not describe the scene. Try turning around slowly.',
      );
    }

    return VisionResult(
      success: true,
      message: description,
      detectedText: description,
    );
  }

  // ============================================================
  // HELPERS
  // ============================================================

  static List<String> _extractObjectNames(Map<String, dynamic> body) {
    final objects = body['objects'];

    if (objects is! List) return const [];

    final names = <String>[];

    for (final item in objects) {
      if (item is Map) {
        final name = item['object']?.toString().trim();
        if (name != null && name.isNotEmpty) names.add(name);
      }
    }

    return names;
  }

  static String _joinNames(List<String> names) {
    if (names.isEmpty) return '';
    if (names.length == 1) return names.first;
    return '${names.sublist(0, names.length - 1).join(', ')} '
        'and ${names.last}';
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }
}
