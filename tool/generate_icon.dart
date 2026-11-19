// Generates the app icon PNGs in assets/icon/.
//
//   dart run tool/generate_icon.dart
//   dart run flutter_launcher_icons
import 'dart:io';

import 'package:image/image.dart' as img;

const _size = 1024;
const _ss = 2; // supersampling factor for smooth edges

img.Color _rgb(int hex, [int a = 255]) => img.ColorRgba8((hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF, a);

/// Draws the calendar glyph centred on the canvas, [scale] relative to the full icon.
void _drawCalendar(img.Image canvas, double scale) {
  final s = canvas.width;
  int px(double f) => (f * s).round();
  final w = 0.62 * scale, h = 0.58 * scale;
  final left = 0.5 - w / 2, top = 0.5 - h / 2 + 0.02 * scale;
  final right = left + w, bottom = top + h;
  final radius = px(0.08 * scale).toDouble();

  // Soft shadow.
  img.fillRect(canvas,
      x1: px(left), y1: px(top + 0.025 * scale), x2: px(right), y2: px(bottom + 0.025 * scale),
      color: _rgb(0x1A237E, 90), radius: radius);

  // Page with coral header.
  img.fillRect(canvas, x1: px(left), y1: px(top), x2: px(right), y2: px(bottom), color: _rgb(0xFF7043), radius: radius);
  final headerBottom = top + 0.17 * scale;
  img.fillRect(canvas,
      x1: px(left), y1: px(headerBottom), x2: px(right), y2: px(bottom), color: _rgb(0xFFFFFF), radius: radius);
  img.fillRect(canvas,
      x1: px(left), y1: px(headerBottom), x2: px(right), y2: px(headerBottom + 0.1 * scale), color: _rgb(0xFFFFFF));

  // Binder rings.
  for (final x in [0.5 - 0.15 * scale, 0.5 + 0.15 * scale]) {
    img.fillRect(canvas,
        x1: px(x - 0.025 * scale), y1: px(top - 0.06 * scale),
        x2: px(x + 0.025 * scale), y2: px(top + 0.07 * scale),
        color: _rgb(0x283593), radius: px(0.025 * scale).toDouble());
  }

  // Day grid: 4 columns x 3 rows, one highlighted day.
  const cols = 4, rows = 3;
  final gridLeft = left + 0.07 * scale, gridTop = headerBottom + 0.06 * scale;
  final cellW = (w - 0.14 * scale) / cols, cellH = (bottom - 0.06 * scale - gridTop) / rows;
  final dot = 0.034 * scale;
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final cx = gridLeft + cellW * (c + 0.5), cy = gridTop + cellH * (r + 0.5);
      if (r == 1 && c == 2) {
        img.fillCircle(canvas, x: px(cx), y: px(cy), radius: px(0.047 * scale), color: _rgb(0x3F51B5));
      } else {
        img.fillRect(canvas,
            x1: px(cx - dot), y1: px(cy - dot), x2: px(cx + dot), y2: px(cy + dot),
            color: _rgb(0xC5CAE9), radius: px(0.012 * scale).toDouble());
      }
    }
  }
}

img.Image _render({required bool background, required double scale}) {
  final s = _size * _ss;
  final canvas = img.Image(width: s, height: s, numChannels: 4);
  if (background) {
    // Diagonal indigo gradient.
    const from = [0x5C, 0x6B, 0xC0], to = [0x30, 0x3F, 0x9F];
    for (var y = 0; y < s; y++) {
      for (var x = 0; x < s; x++) {
        final t = (x + y) / (2 * s);
        canvas.setPixelRgba(
          x,
          y,
          (from[0] + (to[0] - from[0]) * t).round(),
          (from[1] + (to[1] - from[1]) * t).round(),
          (from[2] + (to[2] - from[2]) * t).round(),
          255,
        );
      }
    }
  } else {
    img.fill(canvas, color: img.ColorRgba8(0, 0, 0, 0));
  }
  _drawCalendar(canvas, scale);
  return img.copyResize(canvas, width: _size, height: _size, interpolation: img.Interpolation.average);
}

void main() {
  final dir = Directory('assets/icon')..createSync(recursive: true);
  File('${dir.path}/icon.png').writeAsBytesSync(img.encodePng(_render(background: true, scale: 1)));
  // Android adaptive icons crop to a circle/squircle: keep the glyph in the 66% safe zone.
  File('${dir.path}/icon_foreground.png').writeAsBytesSync(img.encodePng(_render(background: false, scale: 0.62)));
  stdout.writeln('Iconen geschreven naar ${dir.path}/');
}
