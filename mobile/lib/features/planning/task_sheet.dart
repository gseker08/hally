import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import '../family/family_repository.dart';
import 'planning_repository.dart';

enum _TaskAction { save, toggle, delete }

typedef _TaskEdit = ({String title, String? notes, DateTime? dueAt, bool allDay, List<String> childIds});

/// Opens a task's details. Tapping a task row lands here; only the round check button completes a task directly.
///
/// The sheet itself only collects the user's choice: the API calls run here, on a container captured up front,
/// because the row that opened the sheet may be gone (Today drops done tasks) by the time they finish.
Future<void> showTaskSheet(BuildContext context, WidgetRef ref, {required String familyId, required TaskItem task}) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context);
  final result = await showModalBottomSheet<(_TaskAction, _TaskEdit?)>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _TaskSheet(task: task, familyId: familyId),
  );
  if (result == null) return;

  final repo = container.read(planningRepositoryProvider);
  void refresh() {
    container.invalidate(tasksProvider((familyId, 'Open')));
    container.invalidate(tasksProvider((familyId, 'Done')));
    container.invalidate(todayProvider(familyId));
  }

  SnackBar undoable(String text, Future<void> Function() undo) => SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          key: const Key('task.undo'),
          label: l10n.taskReopen,
          onPressed: () async {
            try {
              await undo();
            } catch (_) {
              messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
            }
            refresh();
          },
        ),
      );

  try {
    switch (result) {
      case (_TaskAction.save, final edit?):
        await repo.updateTask(familyId, task.id,
            title: edit.title,
            notes: edit.notes,
            dueAt: edit.dueAt,
            allDay: edit.allDay,
            assigneeUserId: task.assigneeUserId,
            childIds: edit.childIds);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(content: Text(l10n.taskSavedToast)));
      case (_TaskAction.toggle, _):
        if (task.state == 'Done') {
          await repo.reopenTask(familyId, task.id);
        } else {
          await repo.completeTask(familyId, task.id);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(undoable('🎉  ${l10n.taskDoneToast}', () => repo.reopenTask(familyId, task.id)));
        }
      case (_TaskAction.delete, _):
        await repo.cancelTask(familyId, task.id);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(undoable(l10n.taskDeletedToast, () => repo.reopenTask(familyId, task.id)));
      default:
        return;
    }
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
  }
  refresh();
}

class _TaskSheet extends ConsumerStatefulWidget {
  const _TaskSheet({required this.task, required this.familyId});

  final TaskItem task;
  final String familyId;

  @override
  ConsumerState<_TaskSheet> createState() => _TaskSheetState();
}

class _TaskSheetState extends ConsumerState<_TaskSheet> {
  late final _title = TextEditingController(text: widget.task.title);
  late final _notes = TextEditingController(text: widget.task.notes ?? '');
  late DateTime? _date = widget.task.dueAt == null ? null : DateUtils.dateOnly(widget.task.dueAt!);
  late TimeOfDay? _time = widget.task.dueAt != null && !widget.task.allDay ? TimeOfDay.fromDateTime(widget.task.dueAt!) : null;
  late Set<String> _childIds = widget.task.childIds.toSet();

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = _date ?? DateUtils.dateOnly(now);
    final first = initial.isBefore(now) ? initial : DateUtils.dateOnly(now).subtract(const Duration(days: 1));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateUtils.dateOnly(now).add(const Duration(days: 730)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time ?? const TimeOfDay(hour: 9, minute: 0));
    if (picked != null) setState(() => _time = picked);
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final notes = _notes.text.trim();
    final date = _date;
    final time = _time;
    final dueAt = date == null
        ? null
        : time == null
            ? date
            : DateTime(date.year, date.month, date.day, time.hour, time.minute);
    Navigator.pop<(_TaskAction, _TaskEdit?)>(context, (
      _TaskAction.save,
      (title: title, notes: notes.isEmpty ? null : notes, dueAt: dueAt, allDay: dueAt != null && time == null, childIds: _childIds.toList()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final done = widget.task.state == 'Done';
    final children = ref.watch(familyProvider(widget.familyId)).valueOrNull?.children ?? const <ChildProfile>[];

    return Padding(
      // Keep the fields above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.taskEditTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: HallySpace.md),
            TextField(
              key: const Key('taskSheet.title'),
              controller: _title,
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
            ),
            TextField(
              key: const Key('taskSheet.notes'),
              controller: _notes,
              maxLength: 2000,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.taskNotes),
            ),
            ListTile(
              key: const Key('taskSheet.date'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(_date == null ? l10n.taskNoDate : DateFormat.yMMMEd(locale).format(_date!)),
              trailing: _date == null
                  ? null
                  : IconButton(
                      key: const Key('taskSheet.clearDate'),
                      tooltip: l10n.taskClearDate,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(() {
                        _date = null;
                        _time = null;
                      }),
                    ),
              onTap: _pickDate,
            ),
            if (_date != null)
              ListTile(
                key: const Key('taskSheet.time'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_rounded),
                title: Text(_time == null ? l10n.reviewAllDay : _time!.format(context)),
                trailing: _time == null
                    ? null
                    : IconButton(
                        tooltip: l10n.reviewAllDay,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() => _time = null),
                      ),
                onTap: _pickTime,
              ),
            ChildPicker(children: children, selected: _childIds, onChanged: (ids) => setState(() => _childIds = ids)),
            const SizedBox(height: HallySpace.lg),
            FilledButton(key: const Key('taskSheet.save'), onPressed: _save, child: Text(l10n.eventSave)),
            const SizedBox(height: HallySpace.sm),
            OutlinedButton.icon(
              key: const Key('taskSheet.toggle'),
              onPressed: () => Navigator.pop<(_TaskAction, _TaskEdit?)>(context, (_TaskAction.toggle, null)),
              icon: Icon(done ? Icons.undo_rounded : Icons.check_rounded),
              label: Text(done ? l10n.taskMarkOpen : l10n.taskComplete),
            ),
            const SizedBox(height: HallySpace.xs),
            TextButton.icon(
              key: const Key('taskSheet.delete'),
              onPressed: () => Navigator.pop<(_TaskAction, _TaskEdit?)>(context, (_TaskAction.delete, null)),
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(l10n.taskDelete),
            ),
          ],
        ),
      ),
    );
  }
}
