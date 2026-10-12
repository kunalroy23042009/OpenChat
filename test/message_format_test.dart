import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/widgets/message_format.dart';

String plainOf(List<InlineSpan> spans) =>
    spans.map((s) => (s as TextSpan).text ?? '').join('');

FontWeight? weightOf(List<InlineSpan> spans, int i) =>
    (spans[i] as TextSpan).style?.fontWeight;

void main() {
  const base = TextStyle(fontSize: 15);

  test('bold, italic, strike and code spans parse', () {
    final spans = formatMessageSpans(
      '*bold* and _italic_ and ~strike~ and `code` done',
      base,
    );
    expect(plainOf(spans), 'bold and italic and strike and code done');
    expect(weightOf(spans, 0), FontWeight.w700);
    expect(
      (spans[2] as TextSpan).style?.fontStyle,
      FontStyle.italic,
    );
    expect(
      (spans[4] as TextSpan).style?.decoration,
      TextDecoration.lineThrough,
    );
    expect((spans[6] as TextSpan).style?.fontFamily, 'monospace');
  });

  test('monospace blocks and unmatched markers stay literal', () {
    final block = formatMessageSpans('say ```some *code* here``` ok', base);
    expect(plainOf(block), 'say some *code* here ok');
    expect(
      (block[1] as TextSpan).style?.fontFamily,
      'monospace',
    );
    final lone = formatMessageSpans('a * b _ c', base);
    expect(plainOf(lone), 'a * b _ c');
    expect(lone, hasLength(1));
  });
}
