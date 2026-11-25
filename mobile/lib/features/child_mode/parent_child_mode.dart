import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/design/brand.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/family_repository.dart';
import 'child_mode_repository.dart';
import 'parent_exit.dart';

/// A parent pairs a child's phone: a six-digit code, the phones already paired, the approval switch and extra time.
class ConnectPhoneScreen extends ConsumerStatefulWidget {
  const ConnectPhoneScreen({super.key, required this.familyId, required this.childId});

  final String familyId;
  final String childId;

  @override
  ConsumerState<ConnectPhoneScreen> createState() => _ConnectPhoneScreenState();
}

class _ConnectPhoneScreenState extends ConsumerState<ConnectPhoneScreen> {
  PairingCode? _code;
  bool _loading = false;
  bool _failed = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _newCode();
    // Counts the code down, and notices when the child's phone used it.
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() {});
      ref.invalidate(childDevicesProvider((widget.familyId, widget.childId)));
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _newCode() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final code = await ref.read(childModeRepositoryProvider).pairingCode(widget.familyId, widget.childId);
      if (mounted) setState(() => _code = code);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final family = ref.watch(familyProvider(widget.familyId)).valueOrNull;
    final name = family?.children.where((c) => c.id == widget.childId).firstOrNull?.firstName ?? '';
    final devices = ref.watch(childDevicesProvider((widget.familyId, widget.childId)));
    final approval = ref.watch(childApprovalProvider(widget.familyId));
    final screen = ref.watch(childDeviceScreenProvider((widget.familyId, widget.childId)));
    final expired = _code != null && _code!.expiresAt.isBefore(DateTime.now());
    final locale = Localizations.localeOf(context).toLanguageTag();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.childPhoneTitle(name))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, HallySpace.xl),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(HallySpace.md),
              child: Column(
                children: [
                  Text(l10n.childPhoneSteps, textAlign: TextAlign.center),
                  const SizedBox(height: HallySpace.md),
                  if (_loading && _code == null)
                    const HallyLoading()
                  else if (_failed)
                    Text(l10n.errorGeneric)
                  else if (_code != null)
                    Opacity(
                      opacity: expired ? 0.35 : 1,
                      child: Row(
                        key: const Key('phone.code'),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final digit in _code!.code.split(''))
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              width: 42,
                              height: 54,
                              alignment: Alignment.center,
                              decoration:
                                  BoxDecoration(border: Border.all(color: HallyColors.line, width: 2), borderRadius: BorderRadius.circular(HallyRadius.sm)),
                              child: Text(digit, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: HallySpace.sm),
                  Text(expired ? l10n.childPhoneExpired : l10n.childPhoneCodeValid, style: theme.textTheme.bodySmall),
                  TextButton.icon(
                    key: const Key('phone.newCode'),
                    onPressed: _loading ? null : _newCode,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(l10n.childPhoneNewCode),
                  ),
                ],
              ),
            ),
          ),
          HallySectionHeader(title: l10n.childPhoneOnThis),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(HallySpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final fact in [l10n.childPhoneFact1, l10n.childPhoneFact2(name), l10n.childPhoneFact3, l10n.childPhoneFact4])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.check_rounded, size: 18, color: HallyColors.accent(HallyColors.sage, b)),
                        const SizedBox(width: HallySpace.sm),
                        Expanded(child: Text(fact)),
                      ]),
                    ),
                  const SizedBox(height: HallySpace.sm),
                  Text(l10n.childPhonePermissions, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
          if (devices.valueOrNull?.isNotEmpty ?? false) ...[
            HallySectionHeader(title: l10n.childPhoneDevices),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final d in devices.value!)
                    ListTile(
                      key: Key('phone.device.${d.id}'),
                      leading: const HallyIconBadge(icon: Icons.smartphone_rounded, color: HallyColors.mist),
                      title: Text(d.name ?? l10n.childPhoneUnnamed(name)),
                      subtitle: Text(l10n.childPhoneLastSeen(DateFormat('d MMM HH:mm', locale).format(d.lastSeenAt))),
                      trailing: IconButton(
                        key: Key('phone.unpair.${d.id}'),
                        tooltip: l10n.childPhoneUnpair,
                        icon: const Icon(Icons.link_off_rounded),
                        onPressed: () => _unpair(d),
                      ),
                    ),
                ],
              ),
            ),
            HallySectionHeader(title: l10n.childPhoneScreen),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(HallySpace.md),
                child: screen.when(
                  loading: () => const HallyLoading(),
                  error: (_, __) => Text(l10n.errorGeneric),
                  data: (s) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.limitMinutes == null ? l10n.childPhoneUsedNoLimit(s.usedSeconds ~/ 60) : l10n.childPhoneUsed(s.usedSeconds ~/ 60, s.limitMinutes!),
                        style: theme.textTheme.titleSmall,
                      ),
                      if (s.locked) Padding(padding: const EdgeInsets.only(top: 4), child: HallyPill(label: l10n.childPhoneLocked, color: HallyColors.apricot)),
                      const SizedBox(height: HallySpace.sm),
                      Wrap(spacing: HallySpace.sm, children: [
                        for (final m in const [15, 30, 60])
                          ActionChip(
                            key: Key('phone.give.$m'),
                            avatar: const Icon(Icons.add_rounded, size: 18),
                            label: Text(l10n.kidMinutes(m)),
                            onPressed: () => _give(m),
                          ),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ],
          HallySectionHeader(title: l10n.exitPinSection),
          _ExitPinCard(familyId: widget.familyId, childName: name),
          Padding(
            padding: const EdgeInsets.only(top: HallySpace.xs),
            child: Text(l10n.exitPinNote, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          HallySectionHeader(title: l10n.kidJarTitleParent),
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile(
              key: const Key('phone.approval'),
              secondary: const CherryIcon(size: 28),
              title: Text(l10n.childApprovalTitle),
              subtitle: Text(l10n.childApprovalBody),
              value: approval.valueOrNull ?? true,
              onChanged: approval.hasValue
                  ? (v) async {
                      await ref.read(childModeRepositoryProvider).setRequireApproval(widget.familyId, v);
                      ref.invalidate(childApprovalProvider(widget.familyId));
                    }
                  : null,
            ),
          ),
          const SizedBox(height: HallySpace.sm),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: const Key('phone.activities'),
              leading: const Text('🤸', style: TextStyle(fontSize: 24)),
              title: Text(l10n.actSettingsTitle),
              subtitle: Text(l10n.actSettingsBody),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/activities?familyId=${widget.familyId}'),
            ),
          ),
          const SizedBox(height: HallySpace.sm),
          Card(
            margin: const EdgeInsets.only(bottom: HallySpace.sm),
            child: ListTile(
              key: const Key('phone.allowance'),
              leading: const Text('💰', style: TextStyle(fontSize: 24)),
              title: Text(l10n.allowanceTitle),
              subtitle: Text(l10n.allowancePhoneTileBody),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/allowance/${widget.childId}?familyId=${widget.familyId}'),
            ),
          ),
          Card(
            margin: const EdgeInsets.only(bottom: HallySpace.sm),
            child: ListTile(
              key: const Key('phone.asks'),
              leading: const Text('🙋', style: TextStyle(fontSize: 24)),
              title: Text(l10n.askPhoneTile),
              subtitle: Text(l10n.askPhoneTileBody),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/ask-presets?familyId=${widget.familyId}'),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: const Key('phone.bedtime'),
              leading: const Text('🌙', style: TextStyle(fontSize: 24)),
              title: Text(l10n.bedSettingsTitle),
              subtitle: Text(l10n.bedSettingsBody),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/bedtime/${widget.childId}?familyId=${widget.familyId}'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _give(int minutes) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(childModeRepositoryProvider).grant(widget.familyId, widget.childId, minutes);
      ref.invalidate(childDeviceScreenProvider((widget.familyId, widget.childId)));
      messenger.showSnackBar(SnackBar(content: Text(l10n.childPhoneGiven(minutes))));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
  }

  Future<void> _unpair(ChildDevice d) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.childPhoneUnpair),
        content: Text(l10n.childPhoneUnpairConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
          FilledButton(key: const Key('phone.unpair.confirm'), onPressed: () => Navigator.pop(context, true), child: Text(l10n.childPhoneUnpair)),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(childModeRepositoryProvider).unpair(widget.familyId, widget.childId, d.id);
    ref.invalidate(childDevicesProvider((widget.familyId, widget.childId)));
  }
}

/// On a parent's Today: what the children marked done, with Onayla / Henüz değil. Hidden when nothing waits.
class ChildClaimsCard extends ConsumerWidget {
  const ChildClaimsCard({super.key, required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final claims = ref.watch(childClaimsProvider(familyId)).valueOrNull ?? const [];
    if (claims.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;

    Future<void> decide(ChildClaim c, bool approve) async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ref.read(childModeRepositoryProvider).decide(familyId, c.id, approve: approve);
        if (approve) messenger.showSnackBar(SnackBar(content: Text(l10n.claimApproved(c.childName))));
      } catch (_) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
      }
      ref.invalidate(childClaimsProvider(familyId));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HallySectionHeader(title: l10n.claimsTitle, color: HallyColors.cherry, count: claims.length),
        for (final c in claims)
          Card(
            key: Key('claim.${c.id}'),
            margin: const EdgeInsets.only(bottom: HallySpace.sm),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HallyRadius.md),
              side: BorderSide(color: HallyColors.softOf(HallyColors.cherry, b), width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.all(HallySpace.md),
              child: Column(
                children: [
                  Row(children: [
                    HallyAvatar(name: c.childName, size: 36),
                    const SizedBox(width: HallySpace.sm),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l10n.claimLine(c.childName, c.title), style: const TextStyle(fontWeight: FontWeight.w700)),
                        Row(children: [
                          Text('+${c.cherries} ', style: theme.textTheme.bodySmall),
                          const CherryIcon(size: 14),
                          Text(' · ${DateFormat.Hm(Localizations.localeOf(context).toLanguageTag()).format(c.at)}', style: theme.textTheme.bodySmall),
                        ]),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: HallySpace.sm),
                  Row(children: [
                    Expanded(child: FilledButton(key: Key('claim.approve.${c.id}'), onPressed: () => decide(c, true), child: Text(l10n.claimApprove))),
                    const SizedBox(width: HallySpace.sm),
                    Expanded(child: OutlinedButton(key: Key('claim.reject.${c.id}'), onPressed: () => decide(c, false), child: Text(l10n.claimReject))),
                  ]),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The family's exit PIN: whether it is set, and a button to set or change it.
class _ExitPinCard extends ConsumerWidget {
  const _ExitPinCard({required this.familyId, required this.childName});

  final String familyId;
  final String childName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final set = ref.watch(childExitPinProvider(familyId)).valueOrNull;
    return Card(
      key: const Key('phone.exitPin'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(HallySpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const HallyIconBadge(icon: Icons.lock_rounded, color: HallyColors.cherry),
              const SizedBox(width: HallySpace.sm + 4),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l10n.exitPinTitle, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(l10n.exitPinBody(childName), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
            ]),
            const SizedBox(height: HallySpace.sm + 4),
            Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: HallySpace.sm,
                runSpacing: HallySpace.sm,
                children: [
                  if (set != null)
                    HallyPill(
                      key: const Key('phone.exitPin.state'),
                      label: set ? '✓ ${l10n.exitPinSet}' : l10n.exitPinNotSet,
                      color: set ? HallyColors.sage : HallyColors.apricot,
                    ),
                  OutlinedButton(
                    key: const Key('phone.exitPin.edit'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: set == null
                        ? null
                        : () async {
                            final messenger = ScaffoldMessenger.of(context);
                            final saved = await showSetExitPinSheet(context, familyId);
                            if (saved == true) messenger.showSnackBar(SnackBar(content: Text(l10n.exitPinSaved)));
                          },
                    child: Text(set == true ? l10n.exitPinChange : l10n.exitPinCreate),
                  ),
                ]),
          ],
        ),
      ),
    );
  }
}
