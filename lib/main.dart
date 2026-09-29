import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'offline/offline_pack.dart';
import 'services/store.dart';
import 'services/trip_updates.dart';
import 'ui/app_scope.dart';
import 'ui/screens/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore();
  await store.load();
  await OfflinePack.instance.init();
  TripUpdater.instance = TripUpdater(store)..start();
  runApp(AnschlussApp(store: store));
}

class AnschlussApp extends StatelessWidget {
  final AppStore store;
  const AnschlussApp({super.key, required this.store});

  static ThemeData theme(ColorScheme scheme) {
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: scheme.surfaceContainerLow),
    );
  }

  /// Pure black surfaces for OLED screens; containers stay slightly lifted so cards remain visible.
  static ColorScheme amoled(ColorScheme d) => d.copyWith(
    surface: Colors.black,
    surfaceDim: Colors.black,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: const Color(0xFF0C0C0E),
    surfaceContainer: const Color(0xFF121214),
    surfaceContainerHigh: const Color(0xFF1A1A1D),
    surfaceContainerHighest: const Color(0xFF232327),
  );

  @override
  Widget build(BuildContext context) {
    return AppScope(
      store: store,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) => DynamicColorBuilder(
          builder: (ColorScheme? systemLight, ColorScheme? systemDark) {
            final st = store.settings;
            // Android 12+ provides the system (Material You) colours; otherwise the user's own colour.
            final useSystem = st.dynamicColor && systemLight != null && systemDark != null;
            final seed = Color(st.seedColor);
            final light = useSystem ? systemLight : ColorScheme.fromSeed(seedColor: seed);
            var dark = useSystem ? systemDark : ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
            if (st.amoled) dark = amoled(dark);
            return MaterialApp(
              title: 'Anschluss',
              debugShowCheckedModeBanner: false,
              theme: theme(light),
              darkTheme: theme(dark),
              themeMode: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark][st.themeMode.clamp(0, 2)],
              home: const AppShell(),
            );
          },
        ),
      ),
    );
  }
}
