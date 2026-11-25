import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/design/brand.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../child_mode/child_mode_repository.dart';
import 'activities.dart';

String _lang(BuildContext context) => Localizations.localeOf(context).languageCode == 'en' ? 'en' : 'tr';

/// The soft square behind an idea's emoji: green outside, warm colours inside.
Color _ideaColor(ActivityIdea idea, int index) =>
    idea.outdoor ? HallyColors.sage : const [HallyColors.butter, HallyColors.lavender, HallyColors.peach, HallyColors.mist][index % 4];

/// On the child's lock page: "Şimdi ne yapsam?" opens the screen-free ideas.
class KidIdeasCard extends StatelessWidget {
  const KidIdeasCard({super.key, required this.requireApproval});

  final bool requireApproval;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      key: const Key('kid.lock.ideasCard'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(HallySpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('🤸', textAlign: TextAlign.center, style: TextStyle(fontSize: 30)),
            const SizedBox(height: 4),
            Text(l10n.actTitle, textAlign: TextAlign.center, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(l10n.actLockBody, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: HallySpace.sm + 4),
            FilledButton(
              key: const Key('kid.lock.ideas'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KidActivitiesScreen(requireApproval: requireApproval))),
              child: Text(l10n.actShow),
            ),
          ],
        ),
      ),
    );
  }
}

/// The child's list of screen-free ideas, with weather and age on top.
class KidActivitiesScreen extends ConsumerStatefulWidget {
  const KidActivitiesScreen({super.key, required this.requireApproval});

  final bool requireApproval;

  @override
  ConsumerState<KidActivitiesScreen> createState() => _KidActivitiesScreenState();
}

class _KidActivitiesScreenState extends ConsumerState<KidActivitiesScreen> {
  Future<ChildActivities>? _load;
  ChildActivities? _data;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load ??= _fetch();
  }

  Future<ChildActivities> _fetch() async {
    final data = await ref.read(childApiProvider).activities(_lang(context));
    if (mounted) setState(() => _data = data);
    return data;
  }

  Future<void> _open(ActivityIdea idea) async {
    final data = _data;
    if (data == null) return;
    final next = await showModalBottomSheet<_SheetResult>(
      context: context,
      showDragHandle: true,
      builder: (_) => _IdeaSheet(
        idea: idea,
        color: _ideaColor(idea, data.ideas.indexOf(idea)),
        requireApproval: widget.requireApproval,
        canDo: idea.isTodo && !data.limitReached && !_busy,
      ),
    );
    if (!mounted || next == null) return;
    if (next == _SheetResult.done) return _done(idea);
    // "Başka fikir": the next idea still to do, wrapping around.
    final todo = data.ideas.where((i) => i.isTodo).toList();
    if (todo.length < 2) return;
    final at = todo.indexWhere((i) => i.id == idea.id);
    return _open(todo[(at + 1) % todo.length]);
  }

  Future<void> _done(ActivityIdea idea) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final data = await ref.read(childApiProvider).activityDone(idea.id, _lang(context));
      if (!mounted) return;
      setState(() => _data = data);
      ref.invalidate(childHomeProvider);
      messenger.showSnackBar(SnackBar(content: Text(widget.requireApproval ? l10n.actSent : l10n.actEarned(idea.cherries))));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'activity.daily_limit' ? l10n.actLimit : l10n.errorGeneric)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.actTitle)),
      body: FutureBuilder<ChildActivities>(
        future: _load,
        builder: (context, snap) {
          final data = _data;
          if (data == null) {
            if (snap.hasError) return HallyErrorState(onRetry: () => setState(() => _load = _fetch()));
            return const HallyLoading();
          }
          final w = data.weather;
          return ListView(
            padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.xs, HallySpace.md, HallySpace.xl),
            children: [
              Wrap(spacing: HallySpace.sm, runSpacing: HallySpace.sm, children: [
                if (w != null) HallyPill(key: const Key('act.weather'), label: '${w.emoji} ${w.temperatureC}° ${w.label(l10n)}', color: HallyColors.mist),
                if (data.age != null) HallyPill(label: '🎂 ${l10n.actAge(data.age!)}', color: HallyColors.peach),
                HallyPill(key: const Key('act.count'), label: l10n.actToday(data.doneToday, data.dailyLimit), color: HallyColors.cherry),
              ]),
              if (data.limitReached) ...[
                const SizedBox(height: HallySpace.sm),
                Text(l10n.actLimit, key: const Key('act.limit'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: HallySpace.md),
              if (data.ideas.isEmpty) Text(l10n.actEmpty),
              for (final (i, idea) in data.ideas.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: HallySpace.sm),
                  child: _IdeaTile(idea: idea, color: _ideaColor(idea, i), onTap: () => _open(idea)),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _IdeaTile extends StatelessWidget {
  const _IdeaTile({required this.idea, required this.color, required this.onTap});

  final ActivityIdea idea;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final where = idea.outdoor ? l10n.actOutdoor : l10n.actIndoor;
    final sub = [where, if (idea.own) l10n.actOwn else if (idea.hint != null) idea.hint!].join(' · ');
    return Card(
      key: Key('act.idea.${idea.id}'),
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(HallyRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(HallySpace.sm + 4),
          child: Row(children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: HallyColors.softOf(color, b), borderRadius: BorderRadius.circular(16)),
              child: Text(idea.emoji, style: const TextStyle(fontSize: 26)),
            ),
            const SizedBox(width: HallySpace.sm + 4),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(idea.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
            const SizedBox(width: HallySpace.sm),
            switch (idea.state) {
              'Pending' => HallyPill(label: l10n.actPending, color: HallyColors.apricot),
              'Done' => HallyPill(icon: Icons.check_rounded, label: l10n.actDoneState, color: HallyColors.sage),
              _ => Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('+${idea.cherries}',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: HallyColors.accent(HallyColors.cherry, b))),
                  const SizedBox(width: 2),
                  const CherryIcon(size: 18),
                ]),
            },
          ]),
        ),
      ),
    );
  }
}

enum _SheetResult { done, another }

class _IdeaSheet extends StatelessWidget {
  const _IdeaSheet({required this.idea, required this.color, required this.requireApproval, required this.canDo});

  final ActivityIdea idea;
  final Color color;
  final bool requireApproval;
  final bool canDo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HallySpace.md, 0, HallySpace.md, HallySpace.md),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: HallyColors.softOf(color, theme.brightness), borderRadius: BorderRadius.circular(16)),
              child: Text(idea.emoji, style: const TextStyle(fontSize: 26)),
            ),
            const SizedBox(width: HallySpace.sm + 4),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(idea.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                if (idea.hint != null || idea.minutes != null)
                  Text([if (idea.hint != null) idea.hint!, if (idea.minutes != null) l10n.actMinutes(idea.minutes!)].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
          ]),
          const SizedBox(height: HallySpace.sm),
          Text(requireApproval ? l10n.actSheetHint : l10n.actSheetHintNoApproval, style: theme.textTheme.bodyMedium),
          const SizedBox(height: HallySpace.md),
          Row(children: [
            Expanded(
              flex: 3,
              child: FilledButton(
                key: const Key('act.do'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: canDo ? () => Navigator.pop(context, _SheetResult.done) : null,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(child: Text(l10n.actDo(idea.cherries), overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 4),
                  const CherryIcon(size: 16),
                ]),
              ),
            ),
            const SizedBox(width: HallySpace.sm),
            Expanded(
              flex: 2,
              child: OutlinedButton(
                key: const Key('act.another'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => Navigator.pop(context, _SheetResult.another),
                child: Text(l10n.actAnother, overflow: TextOverflow.ellipsis),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ─── Parent side ──────────────────────────────────────────────────────────────

/// Parents: the city for the weather and the family's own ideas.
class FamilyActivitiesScreen extends ConsumerWidget {
  const FamilyActivitiesScreen({super.key, required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final data = ref.watch(familyActivitiesProvider(familyId));
    return Scaffold(
      appBar: AppBar(title: Text(l10n.actSettingsTitle)),
      floatingActionButton: data.hasValue
          ? FloatingActionButton.extended(
              key: const Key('act.add'),
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.actAdd),
            )
          : null,
      body: data.when(
        loading: () => const HallyLoading(),
        error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(familyActivitiesProvider(familyId))),
        data: (d) => ListView(
          padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.xs, HallySpace.md, 120),
          children: [
            Text(l10n.actSettingsBody, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            HallySectionHeader(title: l10n.actCity),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                key: const Key('act.city'),
                leading: const Text('🌤️', style: TextStyle(fontSize: 24)),
                title: Text(d.place?.name ?? l10n.actCityNone),
                subtitle: Text(l10n.actCityHint),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _pickCity(context, ref, d.place != null),
              ),
            ),
            HallySectionHeader(title: l10n.actOwnTitle),
            if (d.own.isEmpty)
              Text(l10n.actOwnEmpty(d.builtIn), style: theme.textTheme.bodyMedium)
            else ...[
              Card(
                margin: EdgeInsets.zero,
                child: Column(children: [
                  for (final o in d.own)
                    ListTile(
                      key: Key('act.own.${o.id}'),
                      leading: Text(o.emoji, style: const TextStyle(fontSize: 24)),
                      title: Text(o.title),
                      subtitle: Text(o.place == 'Outdoor' ? l10n.actOutdoor : l10n.actIndoor),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('+${o.cherries}'),
                        const SizedBox(width: 2),
                        const CherryIcon(size: 16),
                        IconButton(
                          key: Key('act.own.delete.${o.id}'),
                          tooltip: l10n.actDelete,
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () async {
                            await ref.read(activitiesRepositoryProvider).delete(familyId, o.id);
                            ref.invalidate(familyActivitiesProvider(familyId));
                          },
                        ),
                      ]),
                    ),
                ]),
              ),
              const SizedBox(height: HallySpace.sm),
              Text(l10n.actBuiltIn(d.builtIn), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _pickCity(BuildContext context, WidgetRef ref, bool hasCity) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final picked = await showDialog<(WeatherPlace?,)>(context: context, builder: (_) => _CityDialog(lang: _lang(context), canClear: hasCity));
    if (picked == null) return;
    try {
      await ref.read(activitiesRepositoryProvider).setPlace(familyId, picked.$1);
      ref.invalidate(familyActivitiesProvider(familyId));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final idea = await showDialog<({String title, String emoji, int cherries, bool outdoor})>(context: context, builder: (_) => const _AddIdeaDialog());
    if (idea == null) return;
    try {
      await ref.read(activitiesRepositoryProvider).add(familyId, title: idea.title, emoji: idea.emoji, cherries: idea.cherries, outdoor: idea.outdoor);
      ref.invalidate(familyActivitiesProvider(familyId));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    }
  }
}

/// Search a city; pops `(place,)`, or `(null,)` to clear it.
class _CityDialog extends ConsumerStatefulWidget {
  const _CityDialog({required this.lang, required this.canClear});

  final String lang;
  final bool canClear;

  @override
  ConsumerState<_CityDialog> createState() => _CityDialogState();
}

class _CityDialogState extends ConsumerState<_CityDialog> {
  final _query = TextEditingController();
  List<WeatherPlace>? _results;
  bool _searching = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.length < 2) return;
    setState(() => _searching = true);
    try {
      final r = await ref.read(activitiesRepositoryProvider).searchPlaces(q, widget.lang);
      if (mounted) setState(() => _results = r);
    } catch (_) {
      if (mounted) setState(() => _results = const []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final results = _results;
    return AlertDialog(
      title: Text(l10n.actCity),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              key: const Key('act.city.query'),
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: l10n.actCitySearch,
                suffixIcon: IconButton(key: const Key('act.city.search'), icon: const Icon(Icons.search_rounded), onPressed: _search),
              ),
            ),
            if (_searching) const Padding(padding: EdgeInsets.all(HallySpace.md), child: CircularProgressIndicator()),
            if (!_searching && results != null && results.isEmpty)
              Padding(padding: const EdgeInsets.only(top: HallySpace.md), child: Text(l10n.actCityNoResults)),
            if (!_searching && results != null)
              for (final p in results)
                ListTile(
                  key: Key('act.city.${p.name}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.name),
                  subtitle: p.detail.isEmpty ? null : Text(p.detail),
                  onTap: () => Navigator.pop(context, (p,)),
                ),
          ]),
        ),
      ),
      actions: [
        if (widget.canClear) TextButton(onPressed: () => Navigator.pop(context, (null,)), child: Text(l10n.actCityClear)),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
      ],
    );
  }
}

class _AddIdeaDialog extends StatefulWidget {
  const _AddIdeaDialog();

  @override
  State<_AddIdeaDialog> createState() => _AddIdeaDialogState();
}

class _AddIdeaDialogState extends State<_AddIdeaDialog> {
  static const _emojis = ['🎨', '📚', '🧩', '⚽', '🚲', '🧁', '🎵', '☎️', '🌱', '🐶'];
  final _title = TextEditingController();
  String _emoji = _emojis.first;
  int _cherries = 3;
  bool _outdoor = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.actAdd),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            key: const Key('act.add.title'),
            controller: _title,
            maxLength: 60,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: l10n.actAddTitle, hintText: l10n.actAddTitleHint),
            onChanged: (_) => setState(() {}),
          ),
          Text(l10n.actAddEmoji, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(spacing: 4, runSpacing: 4, children: [
            for (final e in _emojis)
              ChoiceChip(label: Text(e, style: const TextStyle(fontSize: 18)), selected: _emoji == e, onSelected: (_) => setState(() => _emoji = e)),
          ]),
          const SizedBox(height: HallySpace.md),
          Text(l10n.actAddCherries, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(spacing: 4, children: [
            for (final c in const [1, 2, 3, 5, 10])
              ChoiceChip(key: Key('act.add.cherries.$c'), label: Text('$c'), selected: _cherries == c, onSelected: (_) => setState(() => _cherries = c)),
          ]),
          const SizedBox(height: HallySpace.md),
          Text(l10n.actAddPlace, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(l10n.actIndoor)),
              ButtonSegment(value: true, label: Text(l10n.actOutdoor)),
            ],
            selected: {_outdoor},
            onSelectionChanged: (s) => setState(() => _outdoor = s.first),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
        FilledButton(
          key: const Key('act.add.save'),
          onPressed: _title.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, (title: _title.text.trim(), emoji: _emoji, cherries: _cherries, outdoor: _outdoor)),
          child: Text(l10n.eventSave),
        ),
      ],
    );
  }
}
