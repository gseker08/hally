import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/analytics/analytics.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../billing/paywall_screen.dart';
import 'family_repository.dart';

/// How long a caregiver's access lasts, picked with chips.
enum AccessPeriod { forever, oneMonth, threeMonths, custom }

/// Invite a parent (same rights) or a caregiver (limited to some children, an end date and, if allowed, health info).
class InvitePartnerScreen extends ConsumerStatefulWidget {
  const InvitePartnerScreen({super.key, required this.familyId});

  final String familyId;

  @override
  ConsumerState<InvitePartnerScreen> createState() => _InvitePartnerScreenState();
}

class _InvitePartnerScreenState extends ConsumerState<InvitePartnerScreen> {
  Invitation? _invitation;
  bool _busy = false;
  bool _caregiver = false;
  final Set<String> _children = {};
  AccessPeriod _period = AccessPeriod.threeMonths;
  DateTime? _customUntil;
  bool _health = false;

  /// Any change to the choices needs a fresh link: the old one carries the old role and limits.
  void _change(VoidCallback fn) => setState(() {
        fn();
        _invitation = null;
      });

  CaregiverAccess _access() {
    final now = DateTime.now();
    final until = switch (_period) {
      AccessPeriod.forever => null,
      AccessPeriod.oneMonth => DateTime(now.year, now.month + 1, now.day, 23, 59),
      AccessPeriod.threeMonths => DateTime(now.year, now.month + 3, now.day, 23, 59),
      AccessPeriod.custom => _customUntil,
    };
    return CaregiverAccess(until: until, childIds: _children.toList(), canSeeHealth: _health);
  }

  Future<Invitation?> _ensureInvitation() async {
    if (_invitation != null) return _invitation;
    setState(() => _busy = true);
    try {
      final inv = await ref.read(familyRepositoryProvider).invite(widget.familyId, caregiver: _caregiver ? _access() : null);
      setState(() => _invitation = inv);
      return inv;
    } catch (e) {
      if (mounted && !openPaywallIfLimited(context, e)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
      }
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareWhatsApp() async {
    final inv = await _ensureInvitation();
    if (inv == null) return;
    ref.read(analyticsProvider).track(AnalyticsEvent.invitationShared, {'channel': 'whatsapp', 'role': _caregiver ? 'caregiver' : 'parent'});
    await launchUrl(Uri.parse(inv.whatsAppUrl), mode: LaunchMode.externalApplication);
  }

  Future<void> _copy() async {
    final inv = await _ensureInvitation();
    if (inv == null || !mounted) return;
    final l10n = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: inv.shareText));
    ref.read(analyticsProvider).track(AnalyticsEvent.invitationShared, {'channel': 'copy', 'role': _caregiver ? 'caregiver' : 'parent'});
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.inviteCopied)));
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _customUntil ?? now.add(const Duration(days: 30)),
      firstDate: now.add(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 3 * 365)),
    );
    if (picked != null) {
      _change(() {
        _period = AccessPeriod.custom;
        _customUntil = DateTime(picked.year, picked.month, picked.day, 23, 59);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final children = ref.watch(familyProvider(widget.familyId)).valueOrNull?.children ?? const <ChildProfile>[];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.inviteWhoTitle)),
      body: HallyPage(
        bottom: Column(
          children: [
            FilledButton.icon(
              key: const Key('invite.whatsapp'),
              onPressed: _busy ? null : _shareWhatsApp,
              icon: const Icon(Icons.chat_outlined),
              label: Text(l10n.inviteWhatsApp),
            ),
            const SizedBox(height: HallySpace.sm),
            OutlinedButton.icon(
              key: const Key('invite.copy'),
              onPressed: _busy ? null : _copy,
              icon: const Icon(Icons.link),
              label: Text(l10n.inviteCopy),
            ),
            TextButton(onPressed: () => context.go('/today'), child: Text(l10n.inviteSkip)),
          ],
        ),
        children: [
          _RoleCard(
            key: const Key('invite.role.parent'),
            icon: Icons.family_restroom_rounded,
            color: HallyColors.powder,
            title: l10n.roleParent,
            body: l10n.inviteRoleParentBody,
            selected: !_caregiver,
            onTap: () => _change(() => _caregiver = false),
          ),
          const SizedBox(height: HallySpace.sm),
          _RoleCard(
            key: const Key('invite.role.caregiver'),
            icon: Icons.volunteer_activism_rounded,
            color: HallyColors.mist,
            title: l10n.roleCaregiver,
            body: l10n.inviteRoleCaregiverBody,
            selected: _caregiver,
            onTap: () => _change(() => _caregiver = true),
          ),
          if (_caregiver) ...[
            if (children.isNotEmpty) ...[
              const SizedBox(height: HallySpace.lg),
              Text(l10n.inviteCaregiverChildren, style: theme.textTheme.titleSmall),
              const SizedBox(height: HallySpace.sm),
              Wrap(
                spacing: HallySpace.sm,
                runSpacing: HallySpace.sm,
                children: [
                  for (final c in children)
                    FilterChip(
                      key: Key('invite.child.${c.id}'),
                      label: Text(c.firstName),
                      // Nothing picked means every child, so all chips show as picked then.
                      selected: _children.isEmpty || _children.contains(c.id),
                      onSelected: (on) => _change(() {
                        if (_children.isEmpty) _children.addAll(children.map((x) => x.id));
                        on ? _children.add(c.id) : _children.remove(c.id);
                        if (_children.length == children.length || _children.isEmpty) _children.clear();
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: HallySpace.lg),
            Text(l10n.inviteCaregiverDuration, style: theme.textTheme.titleSmall),
            const SizedBox(height: HallySpace.sm),
            AccessPeriodChips(
              period: _period,
              customUntil: _customUntil,
              onChanged: (p) => _change(() => _period = p),
              onPickDate: _pickDate,
            ),
            const SizedBox(height: HallySpace.md),
            SwitchListTile(
              key: const Key('invite.health'),
              contentPadding: EdgeInsets.zero,
              value: _health,
              onChanged: (v) => _change(() => _health = v),
              title: Text(l10n.caregiverHealthTitle),
              subtitle: Text(l10n.caregiverHealthBody),
            ),
          ] else ...[
            const SizedBox(height: HallySpace.lg),
            Text(l10n.inviteBody, style: theme.textTheme.bodyMedium),
          ],
          if (_invitation != null) ...[
            const SizedBox(height: HallySpace.lg),
            SelectableText(_invitation!.url, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Süresiz / 1 ay / 3 ay / Tarih seç.
class AccessPeriodChips extends StatelessWidget {
  const AccessPeriodChips({super.key, required this.period, required this.onChanged, required this.onPickDate, this.customUntil});

  final AccessPeriod period;
  final DateTime? customUntil;
  final ValueChanged<AccessPeriod> onChanged;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Wrap(
      spacing: HallySpace.sm,
      runSpacing: HallySpace.sm,
      children: [
        for (final (p, label) in [
          (AccessPeriod.forever, l10n.durationForever),
          (AccessPeriod.oneMonth, l10n.durationOneMonth),
          (AccessPeriod.threeMonths, l10n.durationThreeMonths),
        ])
          ChoiceChip(key: Key('period.${p.name}'), label: Text(label), selected: period == p, onSelected: (_) => onChanged(p)),
        ChoiceChip(
          key: const Key('period.custom'),
          label: Text(period == AccessPeriod.custom && customUntil != null ? formatShortDate(customUntil!, locale) : l10n.durationPick),
          selected: period == AccessPeriod.custom,
          onSelected: (_) => onPickDate(),
        ),
      ],
    );
  }
}

/// "31 Mart 2027" style.
String formatShortDate(DateTime d, String locale) => DateFormat('d MMMM y', locale).format(d);

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final cherry = HallyColors.accent(HallyColors.cherry, b);
    return Semantics(
      selected: selected,
      button: true,
      child: HallyPressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: HallyMotion.medium,
          padding: const EdgeInsets.all(HallySpace.md),
          decoration: BoxDecoration(
            color: selected ? HallyColors.softOf(HallyColors.cherry, b).withValues(alpha: 0.35) : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(HallyRadius.lg),
            border: Border.all(color: selected ? cherry : theme.colorScheme.outlineVariant, width: selected ? 2 : 1.5),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HallyIconBadge(icon: icon, color: color, size: 40),
              const SizedBox(width: HallySpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(body, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_circle_rounded, color: cherry),
            ],
          ),
        ),
      ),
    );
  }
}
