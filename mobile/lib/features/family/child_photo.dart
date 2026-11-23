import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/design/tokens.dart';
import '../../l10n/gen/app_localizations.dart';

/// Side of the square photo that is uploaded. Avatars are at most ~90 dp, so this stays sharp on 3x screens.
const childPhotoSize = 384;

/// Picks a photo from the camera or gallery and lets the parent place it in the circle. Returns a square PNG,
/// or null when cancelled. Overridden in tests, where there is no camera or gallery.
typedef ChildPhotoPicker = Future<Uint8List?> Function(BuildContext context, ImageSource source);

Future<Uint8List?> pickAndCropChildPhoto(BuildContext context, ImageSource source) async {
  final file = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 90);
  if (file == null || !context.mounted) return null;
  final bytes = await file.readAsBytes();
  if (!context.mounted) return null;
  return Navigator.of(context, rootNavigator: true).push<Uint8List>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => ChildPhotoCropPage(bytes: bytes)),
  );
}

final childPhotoPickerProvider = Provider<ChildPhotoPicker>((ref) => pickAndCropChildPhoto);

enum ChildPhotoAction { camera, gallery, remove }

/// Camera, gallery and (when there is a photo) remove.
Future<ChildPhotoAction?> askChildPhotoAction(BuildContext context, {required bool hasPhoto}) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet<ChildPhotoAction>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('child.photo.camera'),
            leading: const Icon(Icons.photo_camera_rounded),
            title: Text(l10n.chatPhotoCamera),
            onTap: () => Navigator.of(context).pop(ChildPhotoAction.camera),
          ),
          ListTile(
            key: const Key('child.photo.gallery'),
            leading: const Icon(Icons.photo_library_rounded),
            title: Text(l10n.chatPhotoGallery),
            onTap: () => Navigator.of(context).pop(ChildPhotoAction.gallery),
          ),
          if (hasPhoto)
            ListTile(
              key: const Key('child.photo.remove'),
              leading: const Icon(Icons.hide_image_outlined),
              title: Text(l10n.childPhotoRemove),
              onTap: () => Navigator.of(context).pop(ChildPhotoAction.remove),
            ),
          const SizedBox(height: HallySpace.sm),
        ],
      ),
    ),
  );
}

/// Full-screen page to zoom and move the photo inside a circle. Returns the square crop as PNG.
class ChildPhotoCropPage extends StatefulWidget {
  const ChildPhotoCropPage({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  State<ChildPhotoCropPage> createState() => _ChildPhotoCropPageState();
}

class _ChildPhotoCropPageState extends State<ChildPhotoCropPage> {
  final _transform = TransformationController();
  ui.Image? _image;
  bool _failed = false;
  bool _busy = false;
  double? _viewport;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _image = frame.image);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    _image?.dispose();
    super.dispose();
  }

  /// Scale that makes the shorter side of the photo fill the circle.
  double _baseScale(ui.Image image, double side) => side / math.min(image.width, image.height);

  void _center(ui.Image image, double side) {
    final base = _baseScale(image, side);
    _transform.value = Matrix4.translationValues(-(image.width * base - side) / 2, -(image.height * base - side) / 2, 0);
  }

  Future<void> _use() async {
    final image = _image;
    final side = _viewport;
    if (image == null || side == null) return;
    setState(() => _busy = true);
    final m = _transform.value;
    final zoom = m.getMaxScaleOnAxis();
    final translation = m.getTranslation();
    final perPixel = _baseScale(image, side) * zoom; // screen points per image pixel
    final src = Rect.fromLTWH(-translation.x / perPixel, -translation.y / perPixel, side / perPixel, side / perPixel);

    final recorder = ui.PictureRecorder();
    final out = childPhotoSize.toDouble();
    Canvas(recorder).drawImageRect(image, src, Rect.fromLTWH(0, 0, out, out), Paint()..filterQuality = FilterQuality.high);
    final cropped = await recorder.endRecording().toImage(childPhotoSize, childPhotoSize);
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();
    if (!mounted) return;
    Navigator.of(context).pop(data?.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(l10n.childPhotoCropTitle),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _failed
                  ? Center(child: Text(l10n.errorGeneric, style: const TextStyle(color: Colors.white)))
                  : image == null
                      ? const Center(child: CircularProgressIndicator())
                      : LayoutBuilder(builder: (context, constraints) {
                          final side = math.min(constraints.maxWidth, constraints.maxHeight) - HallySpace.lg * 2;
                          if (_viewport != side) {
                            final first = _viewport == null;
                            _viewport = side;
                            // The viewer listens to the controller once it is built: change it after this frame then.
                            first ? _center(image, side) : WidgetsBinding.instance.addPostFrameCallback((_) => _center(image, side));
                          }
                          final base = _baseScale(image, side);
                          return Center(
                            child: SizedBox.square(
                              dimension: side,
                              child: Stack(
                                children: [
                                  ClipRect(
                                    child: InteractiveViewer(
                                      key: const Key('child.photo.crop'),
                                      transformationController: _transform,
                                      constrained: false,
                                      minScale: 1,
                                      maxScale: 6,
                                      boundaryMargin: EdgeInsets.zero,
                                      child: SizedBox(
                                        width: image.width * base,
                                        height: image.height * base,
                                        child: RawImage(image: image, fit: BoxFit.fill),
                                      ),
                                    ),
                                  ),
                                  const IgnorePointer(child: CustomPaint(size: Size.infinite, painter: _CircleMask())),
                                ],
                              ),
                            ),
                          );
                        }),
            ),
            Padding(
              padding: const EdgeInsets.all(HallySpace.md),
              child: Text(l10n.childPhotoCropHint, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(HallySpace.lg, 0, HallySpace.lg, HallySpace.lg),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('child.photo.use'),
                  onPressed: image == null || _busy ? null : _use,
                  child: Text(l10n.childPhotoUse),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Darkens the corners so the parent sees the circle the avatar will show.
class _CircleMask extends CustomPainter {
  const _CircleMask();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = Path()..addOval(rect.deflate(1));
    final mask = Path.combine(PathOperation.difference, Path()..addRect(rect), circle);
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawPath(circle, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white70);
  }

  @override
  bool shouldRepaint(_CircleMask oldDelegate) => false;
}
