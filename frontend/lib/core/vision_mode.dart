/// Every vision module My Eyes offers.
///
/// This enum is the single source of truth for a module's identity: its
/// title, its backend `scan_type` (which is what its History button filters
/// on) and its purpose. [ModuleCatalog] adds the spoken explanations and the
/// dashboard wiring on top, so a new module only has to be declared here once
/// plus one catalog entry.
///
/// The `scanType` values are the exact strings the FastAPI backend writes into
/// `scan_history.scan_type`. Changing one silently empties that module's
/// history, so they are treated as a wire contract, not a label.
enum VisionMode {
  scanObject(
    title: 'Scan Object',
    description: 'Identify objects around you',
    supportsFile: false,
    scanType: 'OBJECT_DETECTION',
    resultLabel: 'Detected objects',
  ),

  readText(
    title: 'Read Text',
    description: 'Read text from a document or image',
    supportsFile: true,
    scanType: 'OCR',
    resultLabel: 'Extracted text',
  ),

  medicine(
    title: 'Medicine Detection',
    description: 'Read medicine information',
    supportsFile: false,
    scanType: 'MEDICINE',
    resultLabel: 'Medicine information',
  ),

  product(
    title: 'Product Detection',
    description: 'Read packaged product information',
    supportsFile: false,
    scanType: 'PRODUCT',
    resultLabel: 'Product details',
  ),

  currency(
    title: 'Currency Detection',
    description: 'Recognize currency notes',
    supportsFile: false,
    scanType: 'CURRENCY',
    resultLabel: 'Detected currency',
  ),

  scene(
    title: 'Scene Detection',
    description: 'Understand your surroundings',
    supportsFile: false,
    scanType: 'SCENE',
    resultLabel: 'Scene description',
  ),

  objectFinder(
    title: 'Object Detection',
    description: 'Locate a specific object',
    supportsFile: false,
    // Object Finder reuses the object-detection backend, so both modes share
    // one history stream. Splitting them would give the user two half-empty
    // histories for the same detections.
    scanType: 'OBJECT_DETECTION',
    resultLabel: 'Detected objects',
  );

  final String title;
  final String description;
  final bool supportsFile;

  /// Backend `scan_history.scan_type` for this module. Null means the module
  /// does not persist results and therefore has no History button.
  final String? scanType;

  /// What the stored `result` column holds, used as the spoken heading on a
  /// history row ("Extracted text", "Detected currency", ...).
  final String resultLabel;

  const VisionMode({
    required this.title,
    required this.description,
    required this.supportsFile,
    required this.scanType,
    required this.resultLabel,
  });

  /// True when this module stores scan results and has a History screen.
  bool get hasHistory => scanType != null;

  /// Spoken name of this module's history screen, e.g.
  /// "Currency Detection history". Never "history" on its own, so a blind user
  /// always knows which list they are being read.
  String get historyLabel => '$title history';

  /// What the History button announces before the list loads.
  String historyOpeningSpoken(String companionName) =>
      'Opening your $historyLabel.';

  /// Spoken when the list is empty.
  String historyEmptySpoken() =>
      'There is no history available for $title yet.';
}
