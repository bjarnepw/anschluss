import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'favorites_screen.dart';
import 'home.dart';
import 'trips_screen.dart';

/// Main navigation: map + search, saved trips, favourites. Tabs keep their state (IndexedStack),
/// so the map and a running search survive switching.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final s = context.s;
    final active = store.trips.where((t) => !t.finished).length;
    return ValueListenableBuilder<int>(
      valueListenable: store.tab,
      builder: (context, tab, _) => Scaffold(
        body: IndexedStack(index: tab, children: const [HomeScreen(), TripsScreen(), FavoritesScreen()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => store.tab.value = i,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          height: 68,
          destinations: [
            NavigationDestination(icon: const Icon(Icons.map_outlined), selectedIcon: const Icon(Icons.map), label: s.de ? 'Karte' : 'Map'),
            NavigationDestination(
              icon: Badge(isLabelVisible: active > 0, label: Text('$active'), child: const Icon(Icons.bookmarks_outlined)),
              selectedIcon: Badge(isLabelVisible: active > 0, label: Text('$active'), child: const Icon(Icons.bookmarks)),
              label: s.de ? 'Reisen' : 'Trips',
            ),
            NavigationDestination(
              icon: const Icon(Icons.star_outline_rounded),
              selectedIcon: const Icon(Icons.star_rounded),
              label: s.favorites,
            ),
          ],
        ),
      ),
    );
  }
}
