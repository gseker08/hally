import 'package:flutter/material.dart';

import 'tokens.dart';

/// Colours for one rendering of the cherry mark.
@immutable
class HallyMarkColors {
  const HallyMarkColors({required this.cherry, required this.stem, required this.leaf, this.shine = false});

  final Color cherry;
  final Color stem;
  final Color leaf;
  final bool shine;

  /// White cherries on the brand cherry tile (app icon, splash, dark headers).
  static const onBrand = HallyMarkColors(cherry: Colors.white, stem: HallyColors.cherrySoft, leaf: HallyColors.sagePastel);

  /// Full-colour mark on light surfaces.
  static const onLight = HallyMarkColors(cherry: HallyColors.cherry, stem: HallyColors.cherryStem, leaf: HallyColors.leaf, shine: true);

  /// Full-colour mark on dark surfaces.
  static const onDark = HallyMarkColors(cherry: HallyColors.cherryDark, stem: HallyColors.powderDark, leaf: HallyColors.sageDark, shine: true);
}

/// The Hally mark: two cherries on one branch. The cherries are the two parents sharing the load, the joined
/// stems draw a roof and the leaf is the growing child. Same geometry as mobile/tool/generate_icons.py
/// (a 100x100 design space).
class HallyMark extends StatelessWidget {
  const HallyMark({super.key, this.size = 48, this.colors = HallyMarkColors.onLight});

  final double size;
  final HallyMarkColors colors;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: CustomPaint(painter: _MarkPainter(colors)));
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.c);

  final HallyMarkColors c;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 100;
    canvas.save();
    canvas.scale(k);
    canvas.translate(0, -2);
    final stem = Paint()
      ..color = c.stem
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(Path()..moveTo(50, 22)..cubicTo(45, 34, 37, 47, 32, 60), stem);
    canvas.drawPath(Path()..moveTo(50, 22)..cubicTo(55, 34, 63, 47, 68, 60), stem);
    canvas.drawPath(
      Path()
        ..moveTo(50, 22)
        ..cubicTo(57, 10, 72, 8, 81, 13)
        ..cubicTo(74, 23, 60, 26, 50, 22)
        ..close(),
      Paint()..color = c.leaf,
    );
    final fruit = Paint()..color = c.cherry;
    canvas.drawCircle(const Offset(31, 72), 15, fruit);
    canvas.drawCircle(const Offset(69, 72), 15, fruit);
    if (c.shine) {
      final shine = Paint()..color = Colors.white.withValues(alpha: 0.55);
      for (final x in [25.0, 63.0]) {
        canvas.save();
        canvas.translate(x, 66);
        canvas.rotate(0.52);
        canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: 8.4, height: 12), shine);
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.c != c;
}

/// The app icon as a widget: the mark on a rounded tile. [onDark] gives a white tile for coloured backgrounds.
class HallyLogo extends StatelessWidget {
  const HallyLogo({super.key, this.size = 56, this.onDark = false});

  final double size;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Hally',
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: onDark ? Colors.white : HallyColors.cherry,
          borderRadius: BorderRadius.circular(size * 0.26),
          boxShadow: [BoxShadow(color: (onDark ? Colors.black : HallyColors.cherry).withValues(alpha: 0.14), blurRadius: size * 0.3, offset: Offset(0, size * 0.08))],
        ),
        child: HallyMark(size: size, colors: onDark ? HallyMarkColors.onLight : HallyMarkColors.onBrand),
      ),
    );
  }
}

/// Mark + lowercase "hally" wordmark.
class HallyWordmark extends StatelessWidget {
  const HallyWordmark({super.key, this.height = 32, this.onBrand = false});

  final double height;

  /// True on a cherry or dark background: white letters and white cherries.
  final bool onBrand;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = onBrand ? Colors.white : (dark ? HallyColors.inkDark : HallyColors.ink);
    final colors = onBrand ? HallyMarkColors.onBrand : (dark ? HallyMarkColors.onDark : HallyMarkColors.onLight);
    return Semantics(
      label: 'Hally',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HallyMark(size: height * 1.15, colors: colors),
          SizedBox(width: height * 0.16),
          Text(
            'hally',
            style: TextStyle(fontFamily: HallyFonts.display, fontWeight: FontWeight.w800, fontSize: height, height: 1, letterSpacing: -height * 0.035, color: text),
          ),
        ],
      ),
    );
  }
}
