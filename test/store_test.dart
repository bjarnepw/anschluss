import 'package:anschluss/services/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('settings survive an app restart', () async {
    SharedPreferences.setMockInitialValues({});
    final a = AppStore();
    await a.load();
    a.updateSettings(a.settings.copyWith(seenIntro: true, amoled: true, seedColor: 0xFF1565C0, themeMode: 2));
    await Future<void>.delayed(Duration.zero);

    final b = AppStore();
    await b.load();
    expect(b.settings.seenIntro, isTrue);
    expect(b.settings.amoled, isTrue);
    expect(b.settings.seedColor, 0xFF1565C0);
    expect(b.settings.themeMode, 2);
  });
}
