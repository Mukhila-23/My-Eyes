import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/module_catalog.dart';
import '../core/vision_mode.dart';
import '../screens/common_scanner/common_scanner_screen.dart';

/// Routes a module (by name or [VisionMode]) to the shared scanner
/// screen. Voice commands use [openMode] with autoStart so the
/// camera opens immediately for blind users.
class ModuleRouter {
  static Future<dynamic> openModule(
    BuildContext context,
    String moduleName, {
    bool autoStart = false,
    bool startFromFile = false,
    String? target,
    Uint8List? initialImageBytes,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CommonScannerScreen(
          mode: _getMode(moduleName),
          autoStart: autoStart,
          startFromFile: startFromFile,
          target: target,
          initialImageBytes: initialImageBytes,
        ),
      ),
    );
  }

  static Future<dynamic> openMode(
    BuildContext context,
    VisionMode mode, {
    bool autoStart = false,
    bool startFromFile = false,
    String? target,
    Uint8List? initialImageBytes,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CommonScannerScreen(
          mode: mode,
          autoStart: autoStart,
          startFromFile: startFromFile,
          target: target,
          initialImageBytes: initialImageBytes,
        ),
      ),
    );
  }

  /// Returns null for dashboard entries that are not scanner modules.
  ///
  /// Resolved through [ModuleCatalog], which matches on [VisionMode.title].
  /// There is deliberately no duplicated title switch here: that is what let
  /// the dashboard cards and the scanner drift apart when a module was renamed.
  static VisionMode? modeFor(String moduleName) =>
      ModuleCatalog.forTitle(moduleName)?.mode;

  static VisionMode _getMode(String moduleName) =>
      modeFor(moduleName) ?? VisionMode.scanObject;
}
