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
import 'children.dart';
import 'family_repository.dart';

/// How long a caregiver's access lasts, picked with chips.
enum AccessPeriod { forever, oneMonth, threeMonths, custom }

/// Who is being added: a parent, a caregiver, or a child's own phone.
enum InviteRole { parent, caregiver, child }

/// Invite a parent (same rights) or a caregiver (limited to some children, an end date and, if allowed, health info),
/// or connect a child's phone: pick the child (or type a new one) and get a pairing code.
class InvitePartnerScreen extends ConsumerStatefulWidget {
  const InvitePartnerScreen({super.key, required this.familyId});

  final String familyId;

  @override
  ConsumerState<InvitePartnerScreen> createState() => _InvitePartnerScreenState();
}

class _InvitePartnerScreenState extends ConsumerState<InvitePartnerScreen> {
  Invitation? _invitation;
  bool _busy = false;
  InviteRole _role = InviteRole.parent;
  bool get _caregiver => _role == InviteRole.caregiver;

  /// The child whose phone is being connected; null with [_newChild] means a new child typed here.
  String? _childId;
  bool _newChild = false;
  final _childName = TextEditingController();
  final _childYear = TextEditingController();
  String? _childError;
  final Set<String> _children = {};
  AccessPeriod _period = AccessPeriod.threeMonths;
  DateTime? _customUntil;
  bool _health = false;

  /// Any change to the choices needs a fresh link: the old one carries the old role and limits.
  void _change(VoidCallback fn) => setState(() {
        fn();
        _invitation = null;
      });

  @override
  void dispose() {
    _childName.dispose();
    _childYear.dispose();
    super.dispose();
  }

  /// Creates the child if it is new, then opens the pairing code for its phone.
  Future<void> _getChildCode(List<ChildProfile> children) async {
    final l10n = AppLocalizations.of(context);
    final repo = ref.read(familyRepositoryProvider);
    var childId = _newChild || children.isEmpty ? null : (_childId ?? children.first.id);
    if (childId == null) {
      final name = _childName.text.trim();
      if (name.isEmpty) {
        setState(() => _childError = l10n.inviteChildNameMissing);
        return;
      }
      setState(() {
        _busy = true;
        _childError = null;
      });
      try {
        final year = int.tryParse(_childYear.text.trim());
        final used = children.map((c) => c.color).toSet();
        final color = childColorKeys.firstWhere((k) => !used.contains(k), orElse: () => childColorKeys.first);
        final child = await repo.addChild(widget.familyId, firstName: name, birthYear: year, color: color);
        ref.invalidate(familyProvider(widget.familyId));
        childId = child.id;
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    if (!mounted) return;
    ref.read(analyticsProvider).track(AnalyticsEvent.invitationShared, {'channel': 'code', 'role': 'child'});
    // Replaces this screen, so "Bitti" on the code screen goes back to the family.
    context.pushReplacement('/family/${widget.familyId}/child/$childId/phone');
  }

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
            if (_role == InviteRole.child)
              FilledButton.icon(
                key: const Key('invite.childCode'),
                onPressed: _busy ? null : () => _getChildCode(children),
                icon: const Icon(Icons.key_rounded),
                label: Text(l10n.inviteChildGetCode),
              )
            else ...[
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
            ],
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
            selected: _role == InviteRole.parent,
            onTap: () => _change(() => _role = InviteRole.parent),
          ),
          const SizedBox(height: HallySpace.sm),
          _RoleCard(
            key: const Key('invite.role.caregiver'),
            icon: Icons.volunteer_activism_rounded,
            color: HallyColors.mist,
            title: l10n.roleCaregiver,
            body: l10n.inviteRoleCaregiverBody,
            selected: _caregiver,
            onTap: () => _change(() => _role = InviteRole.caregiver),
          ),
          const SizedBox(height: HallySpace.sm),
          _RoleCard(
            key: const Key('invite.role.child'),
            icon: Icons.child_care_rounded,
            color: HallyColors.apricot,
            title: l10n.roleChild,
            body: l10n.inviteRoleChildBody,
            selected: _role == InviteRole.child,
            onTap: () => _change(() => _role = InviteRole.child),
          ),
          if (_role == InviteRole.child) ...[
            const SizedBox(height: HallySpace.lg),
            Text(l10n.inviteChildWhich, style: theme.textTheme.titleSmall),
            const SizedBox(height: HallySpace.sm),
            Wrap(
              spacing: HallySpace.sm,
              runSpacing: HallySpace.sm,
              children: [
                for (final c in children)
                  ChoiceChip(
                    key: Key('invite.kid.${c.id}'),
                    label: Text(c.firstName),
                    selected: !_newChild && (_childId ?? children.first.id) == c.id,
                    onSelected: (_) => setState(() {
                      _childId = c.id;
                      _newChild = false;
                    }),
                  ),
                ChoiceChip(
                  key: const Key('invite.kid.new'),
                  avatar: const Icon(Icons.add_rounded, size: 18),
                  // Keep the plus: a checkmark over it reads oddly.
                  showCheckmark: false,
                  label: Text(l10n.inviteChildNew),
                  selected: _newChild || children.isEmpty,
                  onSelected: (_) => setState(() => _newChild = true),
                ),
              ],
            ),
            if (_newChild || children.isEmpty) ...[
              const SizedBox(height: HallySpace.md),
              TextField(
                key: const Key('invite.kid.name'),
                controller: _childName,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: l10n.inviteChildName, errorText: _childError),
              ),
              const SizedBox(height: HallySpace.sm),
              TextField(
                key: const Key('invite.kid.year'),
                controller: _childYear,
                keyboardType: TextInputType.number,
                maxLength: 4,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: l10n.inviteChildYear, counterText: ''),
              ),
            ],
            const SizedBox(height: HallySpace.sm),
            Text(l10n.inviteChildNoPhone, style: theme.textTheme.bodySmall),
          ],
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
          ] else if (_role == InviteRole.parent) ...[
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
