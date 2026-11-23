import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/design/tokens.dart';
import '../../core/design/widgets.dart';
import '../../l10n/gen/app_localizations.dart';
import '../family/children.dart';
import 'health_repository.dart';

/// "98,5" or "98.5" to a number; null when empty or invalid.
double? parseHealthNumber(String text) => double.tryParse(text.trim().replaceAll(',', '.'));

String _n(double v, String locale) => NumberFormat.decimalPattern(locale).format(v);

/// A child's health card: basics (blood type, allergies, doctor), appointments, vaccines and growth.
/// Hally keeps what the parents enter; it gives no medical advice.
class HealthScreen extends ConsumerStatefulWidget {
  const HealthScreen({super.key});

  @override
  ConsumerState<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends ConsumerState<HealthScreen> {
  String? _childId;

  Future<void> _act(String familyId, String childId, Future<void> Function(HealthRepository repo) action) async {
    try {
      await action(ref.read(healthRepositoryProvider));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)));
    }
    ref.invalidate(healthCardProvider((familyId, childId)));
  }

  Future<void> _sheet(Widget child) => showModalBottomSheet<void>(context: context, showDragHandle: true, isScrollControlled: true, builder: (_) => child);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final familyId = ref.watch(meProvider).valueOrNull?.primaryFamily?.id;
    if (familyId == null) return const Scaffold(body: HallyLoading());
    final children = watchChildren(ref, familyId);
    final child = children.where((c) => c.id == _childId).firstOrNull ?? children.firstOrNull;
    final locale = Localizations.localeOf(context).toLanguageTag();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.healthTitle)),
      body: child == null
          ? HallyEmptyState(icon: Icons.health_and_safety_rounded, title: l10n.healthTitle, body: l10n.healthNoChildren)
          : ref.watch(healthCardProvider((familyId, child.id))).when(
                loading: () => const HallyLoading(),
                error: (_, __) => HallyErrorState(onRetry: () => ref.invalidate(healthCardProvider((familyId, child.id)))),
                data: (card) {
                  final p = card.profile;
                  final upcoming = card.appointments.where((a) => !a.past).toList();
                  final last = card.growth.isEmpty ? null : card.growth.last;
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(HallySpace.md, HallySpace.sm, HallySpace.md, 48),
                    children: [
                      if (children.length > 1)
                        Wrap(
                          spacing: HallySpace.sm,
                          children: [
                            for (final c in children)
                              ChoiceChip(
                                key: Key('health.child.${c.id}'),
                                avatar: ChildBadge(child: c, size: 22),
                                label: Text(c.firstName),
                                selected: c.id == child.id,
                                onSelected: (_) => setState(() => _childId = c.id),
                              ),
                          ],
                        ),
                      const SizedBox(height: HallySpace.sm),
                      // Basics
                      Card(
                        color: HallyColors.skySoft,
                        child: Padding(
                          padding: const EdgeInsets.all(HallySpace.md),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(child: Text(l10n.healthBasics, style: theme.textTheme.titleMedium?.copyWith(color: HallyColors.ink))),
                                  TextButton.icon(
                                    key: const Key('health.editProfile'),
                                    style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                                    onPressed: () => _sheet(_ProfileSheet(familyId: familyId, childId: child.id, profile: p)),
                                    icon: const Icon(Icons.edit_rounded, size: 18),
                                    label: Text(l10n.healthEdit),
                                  ),
                                ],
                              ),
                              if (p.isEmpty) Text(l10n.healthBasicsEmpty, style: theme.textTheme.bodyMedium?.copyWith(color: HallyColors.ink)),
                              if (p.bloodType != null) _Line(icon: Icons.bloodtype_rounded, label: l10n.healthBloodType, value: p.bloodType!),
                              if (p.allergies != null)
                                _Line(key: const Key('health.allergies'), icon: Icons.warning_amber_rounded, label: l10n.healthAllergies, value: p.allergies!, strong: true),
                              if (p.conditions != null) _Line(icon: Icons.monitor_heart_rounded, label: l10n.healthConditions, value: p.conditions!),
                              if (p.doctorName != null || p.doctorPhone != null)
                                _Line(
                                  icon: Icons.medical_services_rounded,
                                  label: l10n.healthDoctor,
                                  value: [p.doctorName, p.doctorPhone].whereType<String>().join(' · '),
                                  onTap: p.doctorPhone == null ? null : () => launchUrl(Uri(scheme: 'tel', path: p.doctorPhone!.replaceAll(' ', ''))),
                                ),
                              if (p.notes != null) _Line(icon: Icons.notes_rounded, label: l10n.healthNotes, value: p.notes!),
                            ],
                          ),
                        ),
                      ),
                      // Appointments
                      _Header(
                        title: l10n.healthAppointments,
                        addKey: const Key('health.addAppointment'),
                        onAdd: () => _sheet(_AppointmentSheet(familyId: familyId, childId: child.id)),
                      ),
                      if (card.appointments.isEmpty) Text(l10n.healthNoAppointments),
                      for (final a in card.appointments)
                        Dismissible(
                          key: Key('health.appointment.${a.id}'),
                          direction: DismissDirection.endToStart,
                          background: _deleteBackground(),
                          onDismissed: (_) => _act(familyId, child.id, (r) => r.deleteAppointment(familyId, child.id, a.id)),
                          child: Card(
                            child: ListTile(
                              leading: Icon(Icons.event_rounded, color: a.past ? HallyColors.inkMuted : HallyColors.sky),
                              title: Text(a.title, style: a.past ? const TextStyle(color: HallyColors.inkMuted) : null),
                              subtitle: Text([DateFormat.MMMEd(locale).add_Hm().format(a.startsAt), if (a.doctor != null) a.doctor!, if (a.location != null) a.location!]
                                  .join(' · ')),
                            ),
                          ),
                        ),
                      if (upcoming.isNotEmpty) Text(l10n.healthReminderNote, style: theme.textTheme.bodySmall),
                      // Vaccines
                      _Header(
                        title: l10n.healthVaccines,
                        addKey: const Key('health.addVaccine'),
                        onAdd: () => _sheet(_VaccineSheet(familyId: familyId, childId: child.id)),
                      ),
                      if (card.vaccines.isEmpty) Text(l10n.healthNoVaccines),
                      for (final v in card.vaccines)
                        Dismissible(
                          key: Key('health.vaccine.${v.id}'),
                          direction: DismissDirection.endToStart,
                          background: _deleteBackground(),
                          onDismissed: (_) => _act(familyId, child.id, (r) => r.deleteVaccine(familyId, child.id, v.id)),
                          child: Card(
                            child: ListTile(
                              leading: Icon(v.given ? Icons.check_circle_rounded : Icons.vaccines_rounded,
                                  color: v.given ? HallyColors.mintDeep : (v.overdue ? HallyColors.error : HallyColors.sky)),
                              title: Text(v.name),
                              subtitle: Text(v.given
                                  ? l10n.healthGivenOn(DateFormat.yMMMd(locale).format(v.givenOn!))
                                  : (v.overdue ? l10n.healthOverdue(DateFormat.yMMMd(locale).format(v.dueOn!)) : l10n.healthDueOn(DateFormat.yMMMd(locale).format(v.dueOn!)))),
                              trailing: v.given
                                  ? null
                                  : FilledButton.tonal(
                                      key: Key('health.given.${v.id}'),
                                      style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                                      onPressed: () => _act(familyId, child.id, (r) => r.vaccineGiven(familyId, child.id, v.id)),
                                      child: Text(l10n.healthMarkGiven),
                                    ),
                            ),
                          ),
                        ),
                      // Growth
                      _Header(
                        title: l10n.healthGrowth,
                        addKey: const Key('health.addGrowth'),
                        onAdd: () => _sheet(_GrowthSheet(familyId: familyId, childId: child.id)),
                      ),
                      if (last == null) Text(l10n.healthNoGrowth),
                      if (card.growth.where((g) => g.heightCm != null).length > 1)
                        SizedBox(height: 120, child: CustomPaint(painter: _GrowthPainter([for (final g in card.growth) if (g.heightCm != null) g.heightCm!]))),
                      for (final g in card.growth.reversed)
                        Dismissible(
                          key: Key('health.growth.${g.id}'),
                          direction: DismissDirection.endToStart,
                          background: _deleteBackground(),
                          onDismissed: (_) => _act(familyId, child.id, (r) => r.deleteGrowth(familyId, child.id, g.id)),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.straighten_rounded, color: HallyColors.sky),
                            title: Text([
                              if (g.heightCm != null) '${_n(g.heightCm!, locale)} cm',
                              if (g.weightKg != null) '${_n(g.weightKg!, locale)} kg',
                              if (g.headCm != null) l10n.healthHeadValue(_n(g.headCm!, locale)),
                            ].join(' · ')),
                            subtitle: Text(DateFormat.yMMMd(locale).format(g.measuredOn)),
                          ),
                        ),
                      const SizedBox(height: HallySpace.md),
                      OutlinedButton.icon(
                        onPressed: () => context.push('/medications'),
                        icon: const Icon(Icons.medication_rounded),
                        label: Text(l10n.healthMedicationsLink),
                      ),
                      const SizedBox(height: HallySpace.sm),
                      Text(l10n.healthDisclaimer, style: theme.textTheme.bodySmall?.copyWith(color: HallyColors.inkMuted)),
                    ],
                  );
                },
              ),
    );
  }

  Widget _deleteBackground() => Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: HallySpace.lg),
        child: const Icon(Icons.delete_outline_rounded, color: HallyColors.inkMuted),
      );
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.addKey, required this.onAdd});

  final String title;
  final Key addKey;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: HallySpace.md),
        child: Row(
          children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            IconButton(key: addKey, tooltip: AppLocalizations.of(context).healthAdd, onPressed: onAdd, icon: const Icon(Icons.add_circle_outline_rounded)),
          ],
        ),
      );
}

class _Line extends StatelessWidget {
  const _Line({super.key, required this.icon, required this.label, required this.value, this.strong = false, this.onTap});

  final IconData icon;
  final String label;
  final String value;
  final bool strong;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: HallySpace.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: strong ? HallyColors.error : HallyColors.sky),
            const SizedBox(width: HallySpace.sm),
            Expanded(
              child: Text.rich(TextSpan(children: [
                TextSpan(text: '$label: ', style: theme.textTheme.bodyMedium?.copyWith(color: HallyColors.inkMuted)),
                TextSpan(text: value, style: theme.textTheme.bodyMedium?.copyWith(color: HallyColors.ink, fontWeight: strong ? FontWeight.w700 : null)),
              ])),
            ),
            if (onTap != null) const Icon(Icons.call_rounded, size: 18, color: HallyColors.sky),
          ],
        ),
      ),
    );
  }
}

class _GrowthPainter extends CustomPainter {
  _GrowthPainter(this.values);

  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo).abs() < 0.1 ? 1.0 : hi - lo;
    Offset at(int i) => Offset(8 + i * (size.width - 16) / (values.length - 1), size.height - 8 - (values[i] - lo) / span * (size.height - 16));
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(path, Paint()
      ..color = HallyColors.sky
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round);
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(at(i), 4, Paint()..color = HallyColors.sky);
    }
  }

  @override
  bool shouldRepaint(_GrowthPainter old) => old.values != values;
}

/// Shared shell for the add/edit sheets: busy flag, error text, save button.
abstract class _SheetState<T extends ConsumerStatefulWidget> extends ConsumerState<T> {
  bool busy = false;
  String? error;

  Future<void> run(String familyId, String childId, Future<void> Function(HealthRepository repo) action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action(ref.read(healthRepositoryProvider));
      ref.invalidate(healthCardProvider((familyId, childId)));
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = AppLocalizations.of(context).errorGeneric;
        });
      }
    }
  }

  Widget shell(List<Widget> fields, VoidCallback onSave, Key saveKey) => Padding(
        padding: EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...fields,
              if (error != null) Text(error!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: HallyColors.error)),
              const SizedBox(height: HallySpace.md),
              FilledButton(key: saveKey, onPressed: busy ? null : onSave, child: Text(AppLocalizations.of(context).eventSave)),
            ],
          ),
        ),
      );
}

class _ProfileSheet extends ConsumerStatefulWidget {
  const _ProfileSheet({required this.familyId, required this.childId, required this.profile});

  final String familyId;
  final String childId;
  final HealthProfile profile;

  @override
  ConsumerState<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends _SheetState<_ProfileSheet> {
  late String? _blood = widget.profile.bloodType;
  late final _allergies = TextEditingController(text: widget.profile.allergies);
  late final _conditions = TextEditingController(text: widget.profile.conditions);
  late final _doctor = TextEditingController(text: widget.profile.doctorName);
  late final _phone = TextEditingController(text: widget.profile.doctorPhone);
  late final _notes = TextEditingController(text: widget.profile.notes);

  @override
  void dispose() {
    for (final c in [_allergies, _conditions, _doctor, _phone, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _v(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return shell([
      Text(l10n.healthBloodType, style: Theme.of(context).textTheme.titleSmall),
      Wrap(
        spacing: HallySpace.xs,
        children: [
          for (final b in bloodTypes)
            ChoiceChip(key: Key('health.blood.$b'), label: Text(b), selected: _blood == b, onSelected: (on) => setState(() => _blood = on ? b : null)),
        ],
      ),
      TextField(key: const Key('health.allergiesField'), controller: _allergies, maxLength: 300, decoration: InputDecoration(labelText: l10n.healthAllergies)),
      TextField(controller: _conditions, maxLength: 300, decoration: InputDecoration(labelText: l10n.healthConditions)),
      TextField(controller: _doctor, maxLength: 60, decoration: InputDecoration(labelText: l10n.healthDoctorName)),
      TextField(controller: _phone, maxLength: 30, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: l10n.healthDoctorPhone)),
      TextField(controller: _notes, maxLength: 300, decoration: InputDecoration(labelText: l10n.healthNotes)),
    ], () => run(widget.familyId, widget.childId, (r) => r.saveProfile(widget.familyId, widget.childId, HealthProfile(
          bloodType: _blood,
          allergies: _v(_allergies),
          conditions: _v(_conditions),
          doctorName: _v(_doctor),
          doctorPhone: _v(_phone),
          notes: _v(_notes),
        ))), const Key('health.saveProfile'));
  }
}

class _VaccineSheet extends ConsumerStatefulWidget {
  const _VaccineSheet({required this.familyId, required this.childId});

  final String familyId;
  final String childId;

  @override
  ConsumerState<_VaccineSheet> createState() => _VaccineSheetState();
}

class _VaccineSheetState extends _SheetState<_VaccineSheet> {
  final _name = TextEditingController();
  bool _given = false;
  DateTime _date = DateUtils.dateOnly(DateTime.now());

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final today = DateUtils.dateOnly(DateTime.now());
    return shell([
      TextField(key: const Key('health.vaccineName'), controller: _name, maxLength: 60, decoration: InputDecoration(labelText: l10n.healthVaccineName)),
      SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: false, label: Text(l10n.healthPlanned)),
          ButtonSegment(value: true, label: Text(l10n.healthGiven)),
        ],
        selected: {_given},
        onSelectionChanged: (v) => setState(() {
          _given = v.first;
          if (_given && _date.isAfter(today)) _date = today;
        }),
      ),
      ListTile(
        key: const Key('health.vaccineDate'),
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.event_rounded),
        title: Text(DateFormat.yMMMd(locale).format(_date)),
        onTap: () async {
          final picked = await showDatePicker(
              context: context, initialDate: _date, firstDate: DateTime(today.year - 18), lastDate: _given ? today : DateTime(today.year + 3));
          if (picked != null) setState(() => _date = picked);
        },
      ),
    ], () {
      final name = _name.text.trim();
      if (name.isEmpty) {
        setState(() => error = l10n.pointsTitleRequired);
        return;
      }
      run(widget.familyId, widget.childId,
          (r) => r.addVaccine(widget.familyId, widget.childId, name: name, dueOn: _given ? null : _date, givenOn: _given ? _date : null));
    }, const Key('health.saveVaccine'));
  }
}

class _GrowthSheet extends ConsumerStatefulWidget {
  const _GrowthSheet({required this.familyId, required this.childId});

  final String familyId;
  final String childId;

  @override
  ConsumerState<_GrowthSheet> createState() => _GrowthSheetState();
}

class _GrowthSheetState extends _SheetState<_GrowthSheet> {
  final _height = TextEditingController();
  final _weight = TextEditingController();
  final _head = TextEditingController();

  @override
  void dispose() {
    _height.dispose();
    _weight.dispose();
    _head.dispose();
    super.dispose();
  }

  Widget _field(Key key, TextEditingController c, String label) => TextField(
        key: key,
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        decoration: InputDecoration(labelText: label),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return shell([
      _field(const Key('health.height'), _height, l10n.healthHeight),
      _field(const Key('health.weight'), _weight, l10n.healthWeight),
      _field(const Key('health.head'), _head, l10n.healthHead),
    ], () {
      final h = parseHealthNumber(_height.text);
      final w = parseHealthNumber(_weight.text);
      final hc = parseHealthNumber(_head.text);
      if (h == null && w == null && hc == null) {
        setState(() => error = l10n.healthGrowthRequired);
        return;
      }
      run(widget.familyId, widget.childId, (r) => r.addGrowth(widget.familyId, widget.childId, heightCm: h, weightKg: w, headCm: hc));
    }, const Key('health.saveGrowth'));
  }
}

class _AppointmentSheet extends ConsumerStatefulWidget {
  const _AppointmentSheet({required this.familyId, required this.childId});

  final String familyId;
  final String childId;

  @override
  ConsumerState<_AppointmentSheet> createState() => _AppointmentSheetState();
}

class _AppointmentSheetState extends _SheetState<_AppointmentSheet> {
  final _title = TextEditingController();
  final _doctor = TextEditingController();
  final _place = TextEditingController();
  late DateTime _at = () {
    final t = DateTime.now().add(const Duration(days: 1));
    return DateTime(t.year, t.month, t.day, 10);
  }();
  bool _remind = true;

  @override
  void dispose() {
    _title.dispose();
    _doctor.dispose();
    _place.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final now = DateTime.now();
    return shell([
      TextField(
        key: const Key('health.appointmentTitle'),
        controller: _title,
        maxLength: 120,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: l10n.healthAppointmentTitle),
      ),
      TextField(controller: _doctor, maxLength: 60, decoration: InputDecoration(labelText: l10n.healthDoctorName)),
      TextField(controller: _place, maxLength: 120, decoration: InputDecoration(labelText: l10n.healthPlace)),
      ListTile(
        key: const Key('health.appointmentAt'),
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.schedule_rounded),
        title: Text(DateFormat.yMMMEd(locale).add_Hm().format(_at)),
        onTap: () async {
          final day = await showDatePicker(context: context, initialDate: _at, firstDate: DateTime(now.year, now.month, now.day), lastDate: now.add(const Duration(days: 400)));
          if (day == null || !context.mounted) return;
          final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
          if (time == null) return;
          setState(() => _at = DateTime(day.year, day.month, day.day, time.hour, time.minute));
        },
      ),
      SwitchListTile(contentPadding: EdgeInsets.zero, value: _remind, onChanged: (v) => setState(() => _remind = v), title: Text(l10n.healthRemind)),
    ], () {
      final title = _title.text.trim();
      if (title.isEmpty) {
        setState(() => error = l10n.pointsTitleRequired);
        return;
      }
      String? v(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
      run(widget.familyId, widget.childId,
          (r) => r.addAppointment(widget.familyId, widget.childId, title: title, startsAt: _at, location: v(_place), doctor: v(_doctor), remind: _remind));
    }, const Key('health.saveAppointment'));
  }
}
