import 'package:flutter/widgets.dart';

/// WhatsApp-style inline formatting for message bubbles: `*bold*`,
/// `_italic_`, `~strike~`, triple-backtick monospace blocks, and
/// single-backtick `code`. First match wins, no nesting, unmatched markers
/// render literally. Code spans never format inside.
List<InlineSpan> formatMessageSpans(String text, TextStyle base) {
  final pattern = RegExp(
    r'(```[\s\S]+?```)|(`[^`\n]+?`)|(\*[^*\n]+?\*)|(_[^_\n]+?_)|(~[^~\n]+?~)',
  );
  final spans = <InlineSpan>[];
  var pos = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > pos) {
      spans.add(TextSpan(text: text.substring(pos, match.start), style: base));
    }
    final hit = match.group(0)!;
    if (hit.startsWith('```') && hit.length >= 6) {
      spans.add(
        TextSpan(
          text: hit.substring(3, hit.length - 3),
          style: base.copyWith(fontFamily: 'monospace'),
        ),
      );
    } else if (hit.startsWith('`')) {
      spans.add(
        TextSpan(
          text: hit.substring(1, hit.length - 1),
          style: base.copyWith(fontFamily: 'monospace'),
        ),
      );
    } else if (hit.startsWith('*')) {
      spans.add(
        TextSpan(
          text: hit.substring(1, hit.length - 1),
          style: base.copyWith(fontWeight: FontWeight.w700),
        ),
      );
    } else if (hit.startsWith('_')) {
      spans.add(
        TextSpan(
          text: hit.substring(1, hit.length - 1),
          style: base.copyWith(fontStyle: FontStyle.italic),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: hit.substring(1, hit.length - 1),
          style: base.copyWith(decoration: TextDecoration.lineThrough),
        ),
      );
    }
    pos = match.end;
  }
  if (pos < text.length) {
    spans.add(TextSpan(text: text.substring(pos), style: base));
  }
  if (spans.isEmpty) spans.add(TextSpan(text: text, style: base));
  return spans;
}
