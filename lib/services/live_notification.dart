// Trip notifications: an ongoing "live trip" notification while a trip is underway (next train, arrival,
// change, with a countdown – like a navigation app), and an alert when a refresh finds a change while the app
// is in the background. The live notification is Android only; it runs as a foreground service, which keeps the app
// alive so the trip keeps refreshing with the screen off.
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/journey.dart';
import '../ui/app_scope.dart' show fmtTime;
import '../ui/strings.dart';
import 'live_analysis.dart';
import 'store.dart';

/// Text of the live notification for [j] at [now]: (title, body, countdown target). Null when there is
/// nothing to show (trip over).
(String, String, DateTime)? liveText(Journey j, DateTime now, S s, {int minTransfer = 0}) {
  final live = analyseTrip(j, now, minTransfer: minTransfer);
  final leg = live.leg;
  if (leg == null) return null;
  String delay(int? d) => d != null && d > 0 ? ' (+$d)' : '';
  final next = j.transferList.where((t) => identical(t.arriving, leg)).firstOrNull;
  final warning = live.cancelled != null
      ? s.cancelledAhead(live.cancelled!.line)
      : live.risks.where((r) => r.buffer < 0).map((r) => '${s.missedTransfer}: ${r.transfer.departing.from.name}').firstOrNull;
  final riding = !now.isBefore(leg.dep);
  final title = riding
      ? '${leg.line} → ${leg.to.name}'
      : '${leg.line} ${s.de ? 'ab' : 'at'} ${fmtTime(leg.dep)}${delay(leg.depDelay)}${leg.depPlatform != null ? ' · ${s.platform(leg.depPlatform!)}' : ''}';
  final body = riding
      ? [
          '${s.de ? 'An' : 'Arr.'} ${fmtTime(leg.arr)}${delay(leg.arrDelay)}',
          if (next != null)
            '${s.transfer(next.minutes, next.walkMinutes)} → ${next.departing.line}'
                '${next.departing.depPlatform != null ? ' ${s.platform(next.departing.depPlatform!)}' : ''}',
        ].join(' · ')
      : '${leg.from.name} → ${leg.to.name}';
  return (warning != null ? '⚠ $title' : title, warning ?? body, riding ? leg.arr : leg.dep);
}

class LiveNotifier {
  static final instance = LiveNotifier._();
  LiveNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _service = false;
  String? _shownTrip;

  /// Tapping a notification: open that trip (set by the app, which owns the navigator).
  void Function(String tripId)? onTap;

  static const _liveId = 1;
  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> init() async {
    if (kIsWeb) return;
    try {
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_train'),
          iOS: darwin,
          macOS: darwin,
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        ),
        onDidReceiveNotificationResponse: (r) {
          final id = r.payload;
          if (id != null && id.isNotEmpty) onTap?.call(id);
        },
      );
      _ready = true;
    } catch (_) {
      // No notification support here (e.g. a Linux desktop without a notification daemon): the app works without.
    }
  }

  /// Asks once, when the user starts tracking a trip (Android 13+, iOS, macOS).
  Future<void> askPermission() async {
    if (!_ready) return;
    try {
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
        alert: true,
        sound: true,
      );
      await _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
        alert: true,
        sound: true,
      );
    } catch (_) {}
  }

  /// A refresh found news on [trip] (delay, platform, cancellation …).
  Future<void> changed(SavedTrip trip, List<String> changes, S s) async {
    if (!_ready || changes.isEmpty) return;
    try {
      await _plugin.show(
        id: 100 + trip.id.hashCode % 100000,
        title: '${trip.route.from.name} → ${trip.route.to.name}',
        body: changes.join('\n'),
        payload: trip.id,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'changes',
            s.de ? 'Änderungen an Reisen' : 'Trip changes',
            importance: Importance.high,
            priority: Priority.high,
            styleInformation: BigTextStyleInformation(changes.join('\n')),
          ),
          iOS: const DarwinNotificationDetails(),
          macOS: const DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }

  /// Shows (or updates, or removes) the live notification for the trip that is underway or starts soonest.
  /// Android only: elsewhere there are no ongoing notifications, and a re-posted one every minute is spam.
  Future<void> update(AppStore store) async {
    if (!_ready || !_android) return;
    final s = S(store.settings.language);
    final now = DateTime.now();
    // Underway, or leaving within 2 hours.
    final trip =
        (store.trips.where((t) => !t.finished && t.journey.departure.difference(now).inMinutes <= 120).toList()
              ..sort((a, b) => a.journey.departure.compareTo(b.journey.departure)))
            .firstOrNull;
    final text = trip == null ? null : liveText(trip.journey, now, s, minTransfer: store.settings.minTransferMinutes);
    try {
      if (trip == null || text == null) {
        final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        if (_service) await android?.stopForegroundService();
        if (_shownTrip != null) await _plugin.cancel(id: _liveId);
        _service = false;
        _shownTrip = null;
        return;
      }
      final (title, body, until) = text;
      final android = AndroidNotificationDetails(
        'live',
        s.de ? 'Laufende Reise' : 'Trip underway',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        onlyAlertOnce: true,
        showWhen: true,
        when: until.millisecondsSinceEpoch,
        usesChronometer: true,
        chronometerCountDown: true,
      );
      if (!_service) {
        // Android only allows starting this while the app is in front; it then keeps running in the background.
        await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.startForegroundService(
          id: _liveId,
          title: title,
          body: body,
          notificationDetails: android,
          payload: trip.id,
          foregroundServiceTypes: {AndroidServiceForegroundType.foregroundServiceTypeDataSync},
        );
        _service = true;
      } else {
        await _plugin.show(
          id: _liveId,
          title: title,
          body: body,
          payload: trip.id,
          notificationDetails: NotificationDetails(android: android),
        );
      }
      _shownTrip = trip.id;
    } catch (_) {
      // Starting the service can be refused (e.g. from the background on Android 12+); try again next update.
      _service = false;
    }
  }

  /// Whether the live notification keeps the app alive in the background right now (Android).
  bool get keepsAlive => _service;
}
