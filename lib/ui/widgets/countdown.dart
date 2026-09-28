import 'dart:async';

import 'package:flutter/material.dart';

/// "in 4:32" / "in 1 h 12" / "vor 3 min" – ticks every second while under an hour away.
class Countdown extends StatefulWidget {
  final DateTime target;
  final bool de;
  final TextStyle? style;

  /// Hide when further away than this.
  final Duration showWithin;

  const Countdown({super.key, required this.target, required this.de, this.style, this.showWithin = const Duration(hours: 3)});

  static String format(Duration d, bool de) {
    final past = d.isNegative;
    final a = d.abs();
    String body;
    if (a.inMinutes < 60) {
      body = '${a.inMinutes}:${(a.inSeconds % 60).toString().padLeft(2, '0')}';
    } else {
      body = '${a.inHours} h ${(a.inMinutes % 60).toString().padLeft(2, '0')}';
    }
    if (past) return de ? 'vor $body' : '$body ago';
    return de ? 'in $body' : 'in $body';
  }

  @override
  State<Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<Countdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(Countdown old) {
    super.didUpdateWidget(old);
    if (old.target != widget.target) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final left = widget.target.difference(DateTime.now());
    // Second-by-second only when it matters; otherwise refresh every 15 s to save battery.
    final every = left.inMinutes.abs() < 60 ? const Duration(seconds: 1) : const Duration(seconds: 15);
    _timer = Timer.periodic(every, (_) {
      if (!mounted) return;
      setState(() {});
      final now = widget.target.difference(DateTime.now());
      if (now.inMinutes.abs() < 60 && every.inSeconds > 1) _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.target.difference(DateTime.now());
    if (left > widget.showWithin || left < const Duration(minutes: -30)) return const SizedBox.shrink();
    return Text(
      Countdown.format(left, widget.de),
      style: widget.style ?? TextStyle(fontFeatures: const [FontFeature.tabularFigures()], color: Theme.of(context).colorScheme.primary),
    );
  }
}
