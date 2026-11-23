import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/features/family/child_photo.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

/// A 300x200 PNG: left half red, right half blue.
Future<Uint8List> _wideImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 150, 200), Paint()..color = const Color(0xFFFF0000));
  canvas.drawRect(const Rect.fromLTWH(150, 0, 150, 200), Paint()..color = const Color(0xFF0000FF));
  final image = await recorder.endRecording().toImage(300, 200);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  testWidgets('the crop page returns a centred square PNG', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final bytes = (await tester.runAsync(_wideImage))!;
    Uint8List? result;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('tr'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(builder: (_) => ChildPhotoCropPage(bytes: bytes))),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    // Decoding runs on the real event loop: give it a moment, frame by frame.
    for (var i = 0; i < 20 && find.byKey(const Key('child.photo.crop')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('child.photo.crop')), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('child.photo.use')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(result, isNotNull);

    final decoded = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(result!);
      final image = (await codec.getNextFrame()).image;
      final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      Color at(int x, int y) {
        final i = (y * image.width + x) * 4;
        return Color.fromARGB(255, data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
      }

      return (image.width, image.height, at(10, 192), at(373, 192));
    }))!;
    expect(decoded.$1, childPhotoSize);
    expect(decoded.$2, childPhotoSize);
    // The middle 200x200 of the photo: red on the left, blue on the right.
    expect(decoded.$3, const Color(0xFFFF0000));
    expect(decoded.$4, const Color(0xFF0000FF));
  });
}
