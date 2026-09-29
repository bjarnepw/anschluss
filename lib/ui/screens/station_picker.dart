import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/journey.dart';
import '../../services/search.dart';
import '../app_scope.dart';

/// Full-screen station search: debounced suggestions, recent stations, and "my location".
class StationPicker extends StatefulWidget {
  final String title;
  final String initial;
  const StationPicker({super.key, required this.title, this.initial = ''});

  @override
  State<StationPicker> createState() => _StationPickerState();
}

class _StationPickerState extends State<StationPicker> {
  late final _ctrl = TextEditingController(text: widget.initial);
  Timer? _debounce;
  int _req = 0;
  List<Place> _items = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
    if (widget.initial.trim().length >= 2) _query(widget.initial);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _items = [];
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () => _query(q));
  }

  Future<void> _query(String q) async {
    final id = ++_req;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await searchLocations(q.trim(), offlineOnly: AppScope.read(context).settings.offlineOnly);
      if (!mounted || id != _req) return;
      setState(() => _items = res);
    } catch (e) {
      if (mounted && id == _req) setState(() => _error = e.toString());
    } finally {
      if (mounted && id == _req) setState(() => _loading = false);
    }
  }

  Future<void> _useLocation() async {
    final s = context.s;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw s.noLocation;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) throw s.noLocation;
      final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium))
          .timeout(const Duration(seconds: 15));
      final near = await transitousSource.nearby(pos.latitude, pos.longitude);
      if (!mounted) return;
      if (near.isEmpty) throw s.noLocation;
      // The exact position first (Transitous walks from there), then the nearest stops.
      final here = Place(
        name: s.myLocation,
        lat: pos.latitude,
        lon: pos.longitude,
        kind: PlaceKind.place,
        area: s.de ? 'Genaue Position' : 'Exact position',
      );
      setState(() => _items = [here, ...near.take(7)]);
    } catch (e) {
      if (mounted) setState(() => _error = e is String ? e : '${s.noLocation} ($e)');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final store = context.store;
    final showRecents = _ctrl.text.trim().length < 2 && _items.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: s.stationHint, filled: false, border: InputBorder.none),
          onChanged: _onChanged,
          onSubmitted: (_) {
            if (_items.isNotEmpty) Navigator.pop(context, _items.first);
          },
        ),
        actions: [
          if (_ctrl.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _ctrl.clear();
                _onChanged('');
              },
            ),
        ],
        bottom: _loading ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator(minHeight: 3)) : null,
      ),
      body: ListView(
        children: [
          ListTile(leading: const Icon(Icons.my_location), title: Text(s.myLocation), onTap: _loading ? null : _useLocation),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const Divider(height: 1),
          if (showRecents && store.recentPlaces.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(s.recent, style: Theme.of(context).textTheme.labelLarge),
            ),
            for (final p in store.recentPlaces)
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(p.name),
                subtitle: (p.area?.isNotEmpty ?? false) ? Text(p.area!) : null,
                onTap: () => Navigator.pop(context, p),
              ),
          ],
          for (final p in _items)
            ListTile(
              leading: Icon(switch (p.kind) {
                PlaceKind.stop => Icons.train_outlined,
                PlaceKind.address => Icons.home_outlined,
                PlaceKind.place => p.name == s.myLocation ? Icons.my_location : Icons.place_outlined,
              }),
              title: Text(p.name),
              subtitle: (p.area?.isNotEmpty ?? false) ? Text(p.area!) : null,
              onTap: () => Navigator.pop(context, p),
            ),
        ],
      ),
    );
  }
}
