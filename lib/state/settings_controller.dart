import 'package:flutter/material.dart';

import '../data/stores.dart';

class SettingsController extends ChangeNotifier {
  SettingsController(this._store);

  static const _themeKey = 'settings.themeMode';

  final KeyValueStore _store;
  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;

  Future<void> load() async {
    final stored = await _store.read(_themeKey);
    _themeMode = ThemeMode.values.firstWhere((m) => m.name == stored, orElse: () => ThemeMode.system);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    await _store.write(_themeKey, mode.name);
  }
}
