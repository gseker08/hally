import 'package:flutter_test/flutter_test.dart';
import 'package:hally/features/notifications/device_notifications.dart';
import 'package:hally/features/notifications/ios_background.dart';
import 'package:hally/l10n/gen/app_localizations.dart';
import 'package:flutter/widgets.dart';

void main() {
  test('Verdim on the iPhone medication push becomes a med target', () {
    final t = medGivenTarget(Uri.parse('hally://med/given?family=f1&med=m1'))!;
    expect(t.type, 'med');
    expect(t.familyId, 'f1');
    expect(t.id, 'm1');
    expect(medGivenTarget(Uri.parse('hally://med/given?family=f1')), isNull);
    expect(medGivenTarget(Uri.parse('hally://timer/stop?type=screen&family=f&child=c')), isNull);
  });

  test('a button that worked says nothing; one that failed says why', () {
    final l10n = lookupAppLocalizations(const Locale('tr'));
    expect(actionNotice(const ActionDone(), l10n), isNull);
    final failed = actionNotice(const ActionFailed(), l10n)!;
    expect(failed.title, l10n.noticeActionFailedTitle);
    expect(failed.body, l10n.noticeActionFailedBody);
  });
}
