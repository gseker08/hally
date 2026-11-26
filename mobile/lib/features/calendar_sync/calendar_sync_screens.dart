import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/family_repository.dart';
import 'calendar_sync.dart';

String providerName(AppLocalizations l10n, CalendarProvider p) => switch (p) {
      CalendarProvider.google => l10n.calSyncGoogle,
      CalendarProvider.icloud => l10n.calSyncICloud,
      CalendarProvider.outlook => l10n.calSyncOutlook,
      CalendarProvider.other => l10n.calSyncOther,
    };

/// The short brand word used inside sentences ("Google", "iCloud", "Outlook").
String providerBrand(AppLocalizations l10n, CalendarProvider p) => switch (p) {
      CalendarProvider.google => 'Google',
      CalendarProvider.icloud => 'iCloud',
      CalendarProvider.outlook => 'Outlook',
      CalendarProvider.other => l10n.calSyncOther,
    };

Color? colorFromHex(String? hex) {
  if (hex == null) return null;
  final h = hex.replaceFirst('#', '');
  final rgb = h.length == 8 ? h.substring(2) : h;
  final v = int.tryParse(rgb, radix: 16);
  return v == null || rgb.length != 6 ? null : Color(0xFF000000 | v);
}

/// Hally's own drawing of each calendar (not the vendors' logos).
class ProviderMark extends StatelessWidget {
  const ProviderMark({super.key, required this.provider, this.size = 46});

  final CalendarProvider provider;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final border = Border.all(color: b == Brightness.dark ? HallyColors.lineDark : HallyColors.line, width: 1.5);
    final radius = BorderRadius.circular(size * 0.3);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final now = DateTime.now();
    return switch (provider) {
      CalendarProvider.google => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: radius, border: border),
          alignment: Alignment.center,
          child: ShaderMask(
            shaderCallback: (r) => const LinearGradient(colors: [HallyColors.mist, HallyColors.mist, HallyColors.sage, HallyColors.sage], stops: [0, .5, .5, 1])
                .createShader(r),
            child: Text('31', style: TextStyle(fontFamily: HallyFonts.display, fontWeight: FontWeight.w800, fontSize: size * 0.4, color: Colors.white)),
          ),
        ),
      CalendarProvider.icloud => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: radius, border: border),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(DateFormat.E(locale).format(now).toUpperCase(),
                  maxLines: 1, style: TextStyle(fontSize: size * 0.18, height: 1.1, fontWeight: FontWeight.w700, color: HallyColors.cherry)),
              Text('${now.day}', style: TextStyle(fontFamily: HallyFonts.display, fontWeight: FontWeight.w700, fontSize: size * 0.4, height: 1.05)),
            ],
          ),
        ),
      CalendarProvider.outlook => HallyIconBadge(icon: Icons.grid_view_rounded, color: HallyColors.mist, size: size),
      CalendarProvider.other => HallyIconBadge(icon: Icons.smartphone_rounded, color: HallyColors.sage, size: size),
    };
  }
}

/// "Connect your calendar": shown once on the Calendar tab, and from its link button.
Future<void> showCalendarConnectSheet(BuildContext context, WidgetRef ref) async {
  final picked = await showModalBottomSheet<CalendarProvider>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      Widget row(CalendarProvider p) => ListTile(
            key: Key('calSync.connect.${p.name}'),
            contentPadding: EdgeInsets.zero,
            leading: ProviderMark(provider: p),
            title: Text(providerName(l10n, p), style: theme.textTheme.titleMedium),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).pop(p),
          );
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Transform.rotate(angle: -0.14, child: const ProviderMark(provider: CalendarProvider.google, size: 64)),
                  const SizedBox(width: HallySpace.sm),
                  const ProviderMark(provider: CalendarProvider.icloud, size: 68),
                  const SizedBox(width: HallySpace.sm),
                  Transform.rotate(angle: 0.14, child: const ProviderMark(provider: CalendarProvider.outlook, size: 64)),
                ],
              ),
              const SizedBox(height: HallySpace.lg),
              Text(l10n.calSyncInviteTitle, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: HallySpace.sm),
              Text(l10n.calSyncInviteBody, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: HallySpace.md),
              row(CalendarProvider.google),
              const Divider(height: 1),
              row(CalendarProvider.icloud),
              const Divider(height: 1),
              row(CalendarProvider.outlook),
              const SizedBox(height: HallySpace.md),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  key: const Key('calSync.later'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.calSyncLater),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  final settings = await ref.read(calendarSyncSettingsProvider.future);
  if (settings != null && !settings.inviteDone) {
    await ref.read(calendarSyncSettingsProvider.notifier).save(settings.copyWith(inviteDone: true));
  }
  if (picked != null && context.mounted) await context.push('/calendar-sync/${picked.name}');
}

/// Picks the phone calendars of one provider and who sees them.
class CalendarConnectScreen extends ConsumerStatefulWidget {
  const CalendarConnectScreen({super.key, required this.provider});

  final CalendarProvider provider;

  @override
  ConsumerState<CalendarConnectScreen> createState() => _CalendarConnectScreenState();
}

class _CalendarConnectScreenState extends ConsumerState<CalendarConnectScreen> {
  CalendarAccess? _access;
  List<PhoneCalendar>? _calendars;
  Map<String, ShareMode> _picked = {};
  bool _busyOnly = false;
  bool _export = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load(ask: true);
  }

  Future<void> _load({bool ask = false}) async {
    final phone = ref.read(phoneCalendarGatewayProvider);
    var access = await phone.access();
    if (ask && access == CalendarAccess.notDetermined) {
      access = await phone.requestAccess() ? CalendarAccess.granted : await phone.access();
    }
    List<PhoneCalendar>? calendars;
    final settings = await ref.read(calendarSyncSettingsProvider.future) ?? const CalendarSyncSettings();
    if (access == CalendarAccess.granted) {
      try {
        calendars = [
          for (final c in await phone.calendars())
            if (c.provider == widget.provider && c.id != settings.hallyCalendarId) c,
        ];
      } catch (_) {
        calendars = const [];
      }
    }
    if (!mounted) return;
    setState(() {
      _access = access;
      _calendars = calendars;
      _busyOnly = settings.busyOnly;
      _export = settings.exportEnabled || settings.hallyCalendarId == null;
      final mine = {for (final c in calendars ?? const <PhoneCalendar>[]) c.id};
      _picked = {for (final e in settings.calendars.entries) if (mine.contains(e.key)) e.key: e.value};
      if (_picked.isEmpty) {
        // First time for this account: tick the ordinary calendars, keep them to the parent.
        _picked = {for (final c in calendars ?? const <PhoneCalendar>[]) if (!c.subscribed) c.id: ShareMode.onlyMe};
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final settings = await ref.read(calendarSyncSettingsProvider.future) ??
        CalendarSyncSettings(familyId: (await ref.read(meProvider.future))?.primaryFamily?.id);
    final mine = {for (final c in _calendars ?? const <PhoneCalendar>[]) c.id};
    final calendars = {
      for (final e in settings.calendars.entries) if (!mine.contains(e.key)) e.key: e.value,
      ..._picked,
    };
    await ref.read(calendarSyncSettingsProvider.notifier).save(settings.copyWith(
          calendars: calendars,
          busyOnly: _busyOnly,
          exportEnabled: _export,
          inviteDone: true,
        ));
    await ref.read(calendarSyncServiceProvider).run(force: true);
    ref.invalidate(outsideEventsProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).calSyncDone)));
    if (context.canPop()) {
      context.pop();
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final name = providerName(l10n, widget.provider);
    final calendars = _calendars;
    final Widget body;
    if (_access == null) {
      body = const HallyLoading();
    } else if (_access != CalendarAccess.granted) {
      body = _PermissionNeeded(
        denied: _access == CalendarAccess.denied,
        onAllow: () => _load(ask: true),
        onSettings: () => ref.read(phoneCalendarGatewayProvider).openSettings(),
      );
    } else if (calendars == null || calendars.isEmpty) {
      body = NoAccountHelp(provider: widget.provider, onRetry: () => _load());
    } else {
      final first = ref.watch(meProvider).valueOrNull?.displayName.split(' ').first ?? '';
      final byAccount = <String, List<PhoneCalendar>>{};
      for (final c in calendars) {
        byAccount.putIfAbsent(c.accountName ?? name, () => []).add(c);
      }
      body = ListView(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
        children: [
          _InfoBox(icon: Icons.lock_outline_rounded, text: l10n.calSyncPrivacyNote),
          for (final account in byAccount.entries) ...[
            HallySectionHeader(title: account.key, color: HallyColors.mist),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final c in account.value)
                    _CalendarPickRow(
                      calendar: c,
                      mode: _picked[c.id],
                      onToggle: (on) => setState(() => on ? _picked[c.id] = ShareMode.onlyMe : _picked.remove(c.id)),
                      onMode: (m) => setState(() => _picked[c.id] = m),
                    ),
                ],
              ),
            ),
          ],
          HallySectionHeader(title: l10n.calSyncWhatShows, color: HallyColors.sage),
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile(
              key: const Key('calSync.busyOnly'),
              value: _busyOnly,
              onChanged: (v) => setState(() => _busyOnly = v),
              title: Text(l10n.calSyncBusyOnly),
              subtitle: Text(l10n.calSyncBusyOnlyBody(first)),
            ),
          ),
          HallySectionHeader(title: l10n.calSyncToPhone, color: HallyColors.cherry),
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile(
              key: const Key('calSync.export'),
              value: _export,
              onChanged: (v) => setState(() => _export = v),
              title: Text(l10n.calSyncExport),
              subtitle: Text(l10n.calSyncExportBody),
            ),
          ),
          const SizedBox(height: HallySpace.lg),
          FilledButton(
            key: const Key('calSync.save'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.calSyncConnect),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(name, style: theme.textTheme.titleLarge)),
      body: body,
    );
  }
}

class _CalendarPickRow extends StatelessWidget {
  const _CalendarPickRow({required this.calendar, required this.mode, required this.onToggle, required this.onMode});

  final PhoneCalendar calendar;
  final ShareMode? mode;
  final ValueChanged<bool> onToggle;
  final ValueChanged<ShareMode> onMode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final color = colorFromHex(calendar.colorHex) ?? HallyColors.mist;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HallySpace.sm, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(key: Key('calSync.pick.${calendar.id}'), value: mode != null, onChanged: (v) => onToggle(v ?? false)),
              Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: HallySpace.sm),
              Expanded(
                child: Text(calendar.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(color: mode == null ? theme.colorScheme.onSurfaceVariant : null)),
              ),
            ],
          ),
          if (mode != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, HallySpace.sm, HallySpace.sm),
              child: SegmentedButton<ShareMode>(
                key: Key('calSync.mode.${calendar.id}'),
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                segments: [
                  ButtonSegment(value: ShareMode.onlyMe, icon: const Icon(Icons.lock_outline_rounded, size: 16), label: Text(l10n.calSyncOnlyMe)),
                  ButtonSegment(value: ShareMode.family, icon: const Icon(Icons.groups_rounded, size: 16), label: Text(l10n.calSyncFamily)),
                ],
                selected: {mode!},
                onSelectionChanged: (v) => onMode(v.first),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Container(
      padding: const EdgeInsets.all(HallySpace.md),
      decoration: BoxDecoration(color: HallyColors.softOf(HallyColors.mist, b), borderRadius: BorderRadius.circular(HallyRadius.md)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: HallyColors.readableOn(HallyColors.mist, b)),
          const SizedBox(width: HallySpace.sm),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _PermissionNeeded extends StatelessWidget {
  const _PermissionNeeded({required this.denied, required this.onAllow, required this.onSettings});

  final bool denied;
  final VoidCallback onAllow;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return HallyEmptyState(
      icon: Icons.calendar_month_rounded,
      title: l10n.calSyncPermissionTitle,
      body: l10n.calSyncPermissionBody,
      action: FilledButton(
        key: const Key('calSync.allow'),
        onPressed: denied ? onSettings : onAllow,
        child: Text(denied ? l10n.calSyncOpenSettings : l10n.calSyncAllow),
      ),
    );
  }
}

/// The account isn't on this phone: how to add it, or how to send Hally events there with the iCal link instead.
class NoAccountHelp extends ConsumerWidget {
  const NoAccountHelp({super.key, required this.provider, required this.onRetry});

  final CalendarProvider provider;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final brand = providerBrand(l10n, provider);
    final ios = !kIsWeb && Platform.isIOS;
    final steps = [
      if (ios) l10n.calSyncAddAccountIos(brand) else if (provider == CalendarProvider.icloud) l10n.calSyncAndroidICloud
      else if (provider == CalendarProvider.outlook) l10n.calSyncAndroidOutlook
      else l10n.calSyncAddAccountAndroid(brand),
      l10n.calSyncComeBack,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.lg, HallySpace.md, 48),
      children: [
        Center(child: ProviderMark(provider: provider, size: 72)),
        const SizedBox(height: HallySpace.md),
        Text(l10n.calSyncNoAccountTitle(brand), textAlign: TextAlign.center, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: HallySpace.xs),
        Text(l10n.calSyncNoAccountBody, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: HallySpace.md),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(HallySpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.calSyncNoAccountA, style: theme.textTheme.titleSmall),
                const SizedBox(height: HallySpace.sm),
                for (var i = 0; i < steps.length; i++) _Step(number: i + 1, text: steps[i]),
              ],
            ),
          ),
        ),
        const SizedBox(height: HallySpace.sm),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(HallySpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.calSyncNoAccountB(brand), style: theme.textTheme.titleSmall),
                const SizedBox(height: HallySpace.xs),
                Text(l10n.calSyncNoAccountBBody(brand), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: HallySpace.sm),
                OutlinedButton(
                  key: const Key('calSync.copyFeed'),
                  onPressed: () => copyFeedLink(context, ref),
                  child: Text(l10n.calSyncCopyLink),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: HallySpace.lg),
        FilledButton(key: const Key('calSync.retry'), onPressed: onRetry, child: Text(l10n.calSyncRetry)),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: HallyColors.softOf(HallyColors.powder, b), shape: BoxShape.circle),
            child: Text('$number', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: HallyColors.readableOn(HallyColors.powder, b))),
          ),
          const SizedBox(width: HallySpace.sm),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Copies this phone's iCal link, making one first if this phone has none.
Future<void> copyFeedLink(BuildContext context, WidgetRef ref, {bool renew = false}) async {
  final l10n = AppLocalizations.of(context);
  final familyId = (await ref.read(meProvider.future).catchError((_) => null))?.primaryFamily?.id;
  final settings = await ref.read(calendarSyncSettingsProvider.future).catchError((_) => null) ?? CalendarSyncSettings(familyId: familyId);
  if (familyId == null) return;
  var url = renew ? null : settings.feedUrl;
  try {
    if (url == null) {
      url = (await ref.read(calendarSyncApiProvider).createFeed(familyId)).url;
      await ref.read(calendarSyncSettingsProvider.notifier).save(settings.copyWith(feedUrl: url));
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.calSyncCopied)));
  } catch (_) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
  }
}

/// Profile → Connected calendars: providers, export to the phone, the iCal link and disconnecting.
class ConnectedCalendarsScreen extends ConsumerStatefulWidget {
  const ConnectedCalendarsScreen({super.key});

  @override
  ConsumerState<ConnectedCalendarsScreen> createState() => _ConnectedCalendarsScreenState();
}

class _ConnectedCalendarsScreenState extends ConsumerState<ConnectedCalendarsScreen> {
  List<PhoneCalendar>? _calendars;
  bool? _feedActive;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final phone = ref.read(phoneCalendarGatewayProvider);
    List<PhoneCalendar> calendars = const [];
    try {
      if (await phone.access() == CalendarAccess.granted) calendars = await phone.calendars();
    } catch (_) {}
    bool? feed;
    final familyId = (await ref.read(meProvider.future).catchError((_) => null))?.primaryFamily?.id;
    if (familyId != null) {
      try {
        feed = await ref.read(calendarSyncApiProvider).feedActive(familyId);
      } catch (_) {}
    }
    if (mounted) setState(() => (_calendars = calendars, _feedActive = feed));
  }

  Future<void> _update(CalendarSyncSettings Function(CalendarSyncSettings) change) async {
    final s = await ref.read(calendarSyncSettingsProvider.future);
    if (s == null) return;
    await ref.read(calendarSyncSettingsProvider.notifier).save(change(s));
    await ref.read(calendarSyncServiceProvider).run(force: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final settings = ref.watch(calendarSyncSettingsProvider).valueOrNull ?? const CalendarSyncSettings();
    final calendars = _calendars;
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    final children = familyId == null ? const <ChildProfile>[] : ref.watch(familyProvider(familyId)).valueOrNull?.children ?? const [];
    final hasOther = calendars?.any((c) => c.provider == CalendarProvider.other && c.id != settings.hallyCalendarId) ?? false;

    Widget providerRow(CalendarProvider p) {
      final own = calendars?.where((c) => c.provider == p && c.id != settings.hallyCalendarId).toList() ?? const <PhoneCalendar>[];
      final picked = own.where((c) => settings.calendars.containsKey(c.id)).toList();
      final accounts = {for (final c in picked) c.accountName}.whereType<String>().toList();
      final shared = picked.any((c) => settings.calendars[c.id] == ShareMode.family);
      return ListTile(
        key: Key('calSync.provider.${p.name}'),
        leading: ProviderMark(provider: p, size: 36),
        title: Text(providerName(l10n, p)),
        subtitle: Text(picked.isNotEmpty
            ? [if (accounts.isNotEmpty) accounts.first, l10n.calSyncCalendarCount(picked.length), if (shared && settings.busyOnly) l10n.calSyncBusyLabel]
                .join(' · ')
            : own.isEmpty
                ? l10n.calSyncNoAccount
                : l10n.calSyncNotConnected),
        trailing: picked.isNotEmpty
            ? HallyPill(label: l10n.calSyncConnected, color: HallyColors.sage)
            : OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 14)),
                onPressed: () => _open(p),
                child: Text(l10n.calSyncConnect)),
        onTap: () => _open(p),
      );
    }

    final childName = children.where((c) => c.id == settings.exportChildId).firstOrNull?.firstName;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.calSyncTitle)),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(calendarSyncServiceProvider).run(force: true);
          await _refresh();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
          children: [
            Card(
              margin: EdgeInsets.zero,
              child: Column(children: [
                providerRow(CalendarProvider.google),
                providerRow(CalendarProvider.icloud),
                providerRow(CalendarProvider.outlook),
                if (hasOther) providerRow(CalendarProvider.other),
              ]),
            ),
            HallySectionHeader(title: l10n.calSyncFromHally, color: HallyColors.cherry),
            Card(
              margin: EdgeInsets.zero,
              child: Column(children: [
                SwitchListTile(
                  key: const Key('calSync.settings.export'),
                  value: settings.exportEnabled,
                  title: Text(l10n.calSyncAddToPhone),
                  subtitle: Text(settings.exportEnabled ? l10n.calSyncHallyCalendar(settings.exported.length) : l10n.calSyncExportBody),
                  onChanged: (v) async {
                    final phone = ref.read(phoneCalendarGatewayProvider);
                    if (v && await phone.access() != CalendarAccess.granted && !await phone.requestAccess()) return;
                    await _update((s) => s.copyWith(exportEnabled: v));
                  },
                ),
                if (settings.exportEnabled && children.isNotEmpty)
                  ListTile(
                    key: const Key('calSync.settings.child'),
                    title: Text(l10n.calSyncWhichEvents),
                    subtitle: Text(childName ?? l10n.calSyncWholeFamily),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      final picked = await showModalBottomSheet<String>(
                        context: context,
                        showDragHandle: true,
                        builder: (context) => SafeArea(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            ListTile(title: Text(l10n.calSyncWholeFamily), onTap: () => Navigator.pop(context, '')),
                            for (final c in children) ListTile(title: Text(c.firstName), onTap: () => Navigator.pop(context, c.id)),
                          ]),
                        ),
                      );
                      if (picked != null) await _update((s) => s.copyWith(exportChildId: picked.isEmpty ? null : picked));
                    },
                  ),
              ]),
            ),
            HallySectionHeader(title: l10n.calSyncFeedTitle, color: HallyColors.mist),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(HallySpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l10n.calSyncFeedBody, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: HallySpace.sm),
                    if (settings.feedUrl != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(HallyRadius.sm),
                          border: Border.all(color: theme.colorScheme.outlineVariant),
                        ),
                        child: Text(settings.feedUrl!,
                            key: const Key('calSync.feedUrl'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                      )
                    else if (_feedActive == true)
                      Text(l10n.calSyncFeedHidden, style: theme.textTheme.bodySmall),
                    const SizedBox(height: HallySpace.sm),
                    Row(children: [
                      Expanded(
                        child: FilledButton(
                          key: const Key('calSync.feedCopy'),
                          onPressed: settings.feedUrl == null && _feedActive == true
                              ? null
                              : () async {
                                  await copyFeedLink(context, ref);
                                  await _refresh();
                                },
                          child: Text(settings.feedUrl == null ? l10n.calSyncFeedCreate : l10n.calSyncCopy),
                        ),
                      ),
                      if (settings.feedUrl != null || _feedActive == true) ...[
                        const SizedBox(width: HallySpace.sm),
                        Expanded(
                          child: OutlinedButton(
                            key: const Key('calSync.feedRenew'),
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  content: Text(l10n.calSyncFeedRenewConfirm),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
                                    FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.calSyncFeedRenew)),
                                  ],
                                ),
                              );
                              if (ok == true && context.mounted) {
                                await copyFeedLink(context, ref, renew: true);
                                await _refresh();
                              }
                            },
                            child: Text(l10n.calSyncFeedRenew),
                          ),
                        ),
                      ],
                    ]),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HallySpace.lg),
            if (settings.lastSync != null)
              Center(
                child: Text(l10n.calSyncLastSync(DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).add_Hm().format(settings.lastSync!)),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            if (!settings.isEmpty)
              Center(
                child: TextButton(
                  key: const Key('calSync.disconnect'),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(l10n.calSyncStop),
                        content: Text(l10n.calSyncStopConfirm),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
                          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.calSyncStop)),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await ref.read(calendarSyncServiceProvider).disconnect();
                      ref.invalidate(outsideEventsProvider);
                      await _refresh();
                    }
                  },
                  child: Text(l10n.calSyncStop),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(CalendarProvider p) async {
    await context.push('/calendar-sync/${p.name}');
    await _refresh();
  }
}

/// Runs a sync when the app starts and whenever it comes back to the foreground (at most every few minutes).
class CalendarSyncListener extends ConsumerStatefulWidget {
  const CalendarSyncListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CalendarSyncListener> createState() => _CalendarSyncListenerState();
}

class _CalendarSyncListenerState extends ConsumerState<CalendarSyncListener> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sync();
  }

  Future<void> _sync() async {
    if (!mounted) return;
    try {
      await ref.read(calendarSyncServiceProvider).run();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Bottom sheet for a phone or shared event: where it comes from, and (for this phone's events) open it there.
Future<void> showOutsideEventSheet(BuildContext context, WidgetRef ref, OutsideEvent e) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final source = '${providerName(l10n, e.provider)} · ${e.calendarName}';
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                ProviderMark(provider: e.provider, size: 36),
                const SizedBox(width: HallySpace.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(outsideTitle(l10n, e), style: theme.textTheme.titleMedium),
                    Text(source, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ]),
              const SizedBox(height: HallySpace.md),
              Text(e.mine ? l10n.calSyncFromProvider(source) : l10n.calSyncSharedBy(e.ownerName ?? ''),
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              if (e.mine && e.instanceId != null) ...[
                const SizedBox(height: HallySpace.md),
                OutlinedButton(
                  key: const Key('calSync.openEvent'),
                  onPressed: () async {
                    Navigator.pop(context);
                    try {
                      await ref.read(phoneCalendarGatewayProvider).openEvent(e.instanceId!);
                    } catch (_) {}
                  },
                  child: Text(l10n.calSyncOpenInCalendar),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

String outsideTitle(AppLocalizations l10n, OutsideEvent e) {
  final t = e.title?.trim() ?? '';
  if (!e.busyOnly && t.isNotEmpty) return t;
  return e.ownerName == null || e.ownerName!.isEmpty ? l10n.calSyncBusyLabel : l10n.calSyncBusy(e.ownerName!);
}
