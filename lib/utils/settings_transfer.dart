// Behavior based on DenserMeerkat/June (GPL-3.0)
import 'dart:convert';
import 'package:daily_you/config_provider.dart';

class SettingsTransfer {
  // Device paths, credentials, network consent, app locks and schedules stay
  // device-local. Restoring visual preferences must not change security state.
  static const _settings = <Setting<dynamic>>[
    Settings.theme,
    Settings.followSystemColor,
    Settings.accentColor,
    Settings.paletteStyle,
    Settings.appFont,
    Settings.startingDayOfWeek,
    Settings.calendarSystem,
    Settings.galleryPageViewMode,
    Settings.calendarStreaks,
    Settings.calendarShowMood,
    Settings.markdownEnabled,
    Settings.keyboardAutocorrect,
    Settings.keyboardCapitalization,
    Settings.alwaysOpenNewLog,
    Settings.hideImagesInCalendar,
    Settings.hideImagesInGallery,
    Settings.hideImagesInFlashbacks,
    Settings.showFlashbacks,
    Settings.excludeBadDaysFromFlashbacks,
    Settings.imageQualityLevel,
    Settings.videoQualityLevel,
    Settings.audioQualityLevel,
  ];

  static String encode() => const JsonEncoder.withIndent('  ').convert({
        'format': 'daily-you-settings',
        'version': 1,
        'settings': {
          for (final setting in _settings)
            setting.key:
                ConfigProvider.instance.get(setting) ?? setting.defaultValue
        },
      });

  static Future<void> restore(String document) async {
    final root = jsonDecode(document);
    if (root is! Map ||
        root['format'] != 'daily-you-settings' ||
        root['version'] != 1 ||
        root['settings'] is! Map) {
      throw const FormatException('Unsupported settings backup');
    }
    final values = root['settings'] as Map;
    for (final setting in _settings) {
      if (!values.containsKey(setting.key)) continue;
      final value = values[setting.key];
      final fallback = setting.defaultValue;
      if (!((fallback is bool && value is bool) ||
          (fallback is int && value is int) ||
          (fallback is String && value is String))) {
        throw FormatException('Invalid preference', setting.key);
      }
      final choices = _choices[setting.key];
      if (choices != null && !choices.contains(value)) {
        throw FormatException('Unknown preference value', setting.key);
      }
    }
    for (final setting in _settings) {
      if (values.containsKey(setting.key)) {
        await ConfigProvider.instance.set(setting, values[setting.key]);
      }
    }
  }

  static const _choices = <String, Set<String>>{
    'theme': {'system', 'light', 'dark', 'amoled'},
    'paletteStyle': {
      'tonalSpot',
      'neutral',
      'vibrant',
      'expressive',
      'fidelity',
      'monochrome'
    },
    'appFont': {'system', 'sans-serif', 'serif', 'monospace'},
  };
}
