import 'package:flutter/material.dart';

import '../services/store.dart';
import 'strings.dart';

class AppScope extends InheritedNotifier<AppStore> {
  const AppScope({super.key, required AppStore store, required super.child}) : super(notifier: store);

  static AppStore of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppStore read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

extension ScopeX on BuildContext {
  AppStore get store => AppScope.of(this);
  S get s => S(AppScope.of(this).settings.language);
}

String fmtTime(DateTime d) {
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String fmtDur(int min) => min >= 60 ? '${min ~/ 60} h ${(min % 60).toString().padLeft(2, '0')}' : '$min min';

String fmtEur(double v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} €';

int dayDiff(DateTime a, DateTime b) {
  final la = a.toLocal(), lb = b.toLocal();
  return DateTime(lb.year, lb.month, lb.day).difference(DateTime(la.year, la.month, la.day)).inDays;
}

String fmtDate(DateTime d, bool de) {
  final l = d.toLocal();
  const wdDe = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
  const wdEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${(de ? wdDe : wdEn)[l.weekday - 1]}, ${l.day}.${l.month}.';
}

String fmtAgo(DateTime t, bool de) {
  final m = DateTime.now().difference(t).inMinutes;
  if (m < 1) return de ? 'gerade eben' : 'just now';
  if (m < 60) return de ? 'vor $m min' : '$m min ago';
  final h = m ~/ 60;
  if (h < 24) return de ? 'vor $h h' : '$h h ago';
  return fmtDate(t, de);
}
