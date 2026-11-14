import 'dart:convert';
import 'package:daily_you/config_provider.dart';
import 'package:daily_you/utils/settings_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/config_provider_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useTemporaryConfig();
  test('round trips editor and appearance preferences without private settings',
      () async {
    final config = ConfigProvider.instance;
    await config.set(Settings.markdownEnabled, false);
    await config.set(Settings.paletteStyle, 'expressive');
    await config.set(Settings.webDavPassword, 'private-password');
    await config.set(Settings.allowNetworkAccess, true);
    final backup = SettingsTransfer.encode();
    expect(backup, isNot(contains('private-password')));
    expect(backup, isNot(contains('allowNetworkAccess')));
    await config.set(Settings.markdownEnabled, true);
    await SettingsTransfer.restore(backup);
    expect(config.get(Settings.markdownEnabled), false);
    expect(config.get(Settings.paletteStyle), 'expressive');
  });
  test('validates the whole document before changing any preference', () async {
    final config = ConfigProvider.instance;
    final backup =
        jsonDecode(SettingsTransfer.encode()) as Map<String, dynamic>;
    backup['settings']['markdownEnabled'] = false;
    backup['settings']['theme'] = 99;
    await expectLater(
        SettingsTransfer.restore(jsonEncode(backup)), throwsFormatException);
    expect(config.get(Settings.markdownEnabled), true);
  });
  test(
      'ignores security and network values injected into an otherwise valid file',
      () async {
    final backup =
        jsonDecode(SettingsTransfer.encode()) as Map<String, dynamic>;
    backup['settings']['allowNetworkAccess'] = true;
    backup['settings']['requirePassword'] = false;
    await SettingsTransfer.restore(jsonEncode(backup));
    expect(ConfigProvider.instance.get(Settings.allowNetworkAccess), false);
  });
}
