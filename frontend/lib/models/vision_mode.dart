/// Defines the vision module currently being used by My Eyes.
///
/// All vision-related features use this enum so that we can
/// reuse the same camera, file picker, AI processing and TTS
/// architecture for different modules.
enum VisionMode {
  /// Detect and identify objects using the camera.
  object,

  /// Read printed or handwritten text using OCR.
  text,

  /// Identify medicine and read relevant medicine information.
  medicine,

  /// Identify packaged products and read product information.
  product,

  /// Detect and identify currency notes.
  currency,

  /// Describe the user's surroundings.
  scene,

  /// Continuously search for a requested object.
  objectFinder,
}

/// Extension containing information about each vision module.
extension VisionModeExtension on VisionMode {
  String get title {
    switch (this) {
      case VisionMode.object:
        return 'Scan Object';

      case VisionMode.text:
        return 'Read Text';

      case VisionMode.medicine:
        return 'Medicine Reader';

      case VisionMode.product:
        return 'Product Reader';

      case VisionMode.currency:
        return 'Currency Detector';

      case VisionMode.scene:
        return 'Scene Describer';

      case VisionMode.objectFinder:
        return 'Object Finder';
    }
  }

  String get description {
    switch (this) {
      case VisionMode.object:
        return 'Identify objects around you';

      case VisionMode.text:
        return 'Read text aloud';

      case VisionMode.medicine:
        return 'Read medicine information';

      case VisionMode.product:
        return 'Read packaged product details';

      case VisionMode.currency:
        return 'Recognize currency notes';

      case VisionMode.scene:
        return 'Understand your surroundings';

      case VisionMode.objectFinder:
        return 'Find a specific object';
    }
  }

  /// Whether this module can accept an uploaded file.
  ///
  /// Object Finder is intentionally excluded because it needs
  /// the live camera to search for an object.
  bool get supportsFile {
    switch (this) {
      case VisionMode.object:
        return false;

      case VisionMode.text:
      case VisionMode.medicine:
      case VisionMode.product:
      case VisionMode.currency:
      case VisionMode.scene:
        return true;

      case VisionMode.objectFinder:
        return false;
    }
  }

  /// Whether this module uses the camera.
  bool get supportsCamera {
    return true;
  }

  /// Whether this module requires continuous camera frames.
  ///
  /// Object Finder is different from the other modules because
  /// it needs to continuously search for the requested object.
  bool get requiresLiveCamera {
    return this == VisionMode.objectFinder;
  }
}