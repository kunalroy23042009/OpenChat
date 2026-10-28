import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Renders WhatsApp-style rich text formatting inline within chat bubbles.
///
/// Supported syntax:
/// - *bold* → **bold**
/// - _italic_ → _italic_
/// - ~strikethrough~ → ~~strikethrough~~
/// - ```monospace``` → `monospace`
/// - > quote → blockquote
/// - - item → bullet list
/// - 1. item → numbered list
class FormattedText extends StatefulWidget {
  const FormattedText({
    super.key,
    required this.text,
    this.baseStyle,
    this.linkColor,
  });

  final String text;
  final TextStyle? baseStyle;
  final Color? linkColor;

  @override
  State<FormattedText> createState() => _FormattedTextState();
}

/// Owns the tap recognizers created for URL spans of one build pass.
/// Recognizers attach to painted spans only after the frame exists, so
/// disposal is deferred a full frame past the replacement build.
class _LinkManager {
  final _created = <TapGestureRecognizer>[];

  TapGestureRecognizer forUrl(String url, void Function(String) open) {
    final recognizer = TapGestureRecognizer()..onTap = () => open(url);
    _created.add(recognizer);
    return recognizer;
  }

  void dispose() {
    for (final recognizer in _created) {
      recognizer.dispose();
    }
    _created.clear();
  }
}

class _FormattedTextState extends State<FormattedText> {
  _LinkManager? _links;

  void _disposeLinks() {
    final old = _links;
    _links = null;
    if (old == null) return;
    // The old spans are painted during this frame; release them next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  Widget build(BuildContext context) {
    _disposeLinks();
    final links = _links ??= _LinkManager();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = widget.baseStyle ??
        TextStyle(
          fontSize: 15,
          color: isDark ? Colors.white : const Color(0xFF111B21),
          height: 1.35,
        );

    final lines = widget.text.split('\n');
    final widgets = <Widget>[];
    final buffer = <String>[];

    void flushBuffer() {
      if (buffer.isEmpty) return;
      widgets.add(
        Text.rich(
          TextSpan(
            children: _parseInline(
              buffer.join('\n'),
              base,
              widget.linkColor,
              links,
            ),
          ),
          softWrap: true,
        ),
      );
      buffer.clear();
    }

    for (final line in lines) {
      // Block quote
      if (line.startsWith('> ')) {
        flushBuffer();
        widgets.add(
          _QuoteLine(
            text: line.substring(2),
            base: base,
            linkColor: widget.linkColor,
            links: links,
          ),
        );
        continue;
      }

      // Bullet list
      if (line.startsWith('- ') || line.startsWith('• ') || line.startsWith('* ')) {
        // Don't treat * as bullet if it looks like bold (*text*)
        if (line.startsWith('* ') && !line.startsWith('* ')) {
          buffer.add(line);
          continue;
        }
        flushBuffer();
        widgets.add(
          _BulletLine(
            text: line.substring(2),
            base: base,
            linkColor: widget.linkColor,
            links: links,
          ),
        );
        continue;
      }

      // Numbered list
      final numMatch = RegExp(r'^(\d+)\.\s+(.*)$').firstMatch(line);
      if (numMatch != null) {
        flushBuffer();
        widgets.add(
          _NumberedLine(
            number: numMatch.group(1)!,
            text: numMatch.group(2)!,
            base: base,
            linkColor: widget.linkColor,
            links: links,
          ),
        );
        continue;
      }

      // Monospace block (triple backtick)
      if (line.startsWith('```') && line.endsWith('```') && line.length > 6) {
        flushBuffer();
        widgets.add(_CodeBlock(code: line.substring(3, line.length - 3)));
        continue;
      }

      buffer.add(line);
    }
    flushBuffer();

    if (widgets.length == 1) return widgets.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < widgets.length; i++) ...[
          widgets[i],
          if (i < widgets.length - 1) const SizedBox(height: 2),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _disposeLinks();
    super.dispose();
  }
}

void _openLink(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return;
  launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
}

/// Parses inline formatting: *bold*, _italic_, ~strikethrough~, `code`.
/// URLs become tappable spans; recognizers are owned by [links].
List<InlineSpan> _parseInline(
  String text,
  TextStyle base,
  Color? linkColor,
  _LinkManager links,
) {
  final spans = <InlineSpan>[];
  final regex = RegExp(
    r'(\*(.+?)\*)'     // *bold*
    r'|(_(.+?)_)'      // _italic_
    r'|(~(.+?)~)'      // ~strikethrough~
    r'|(`(.+?)`)'      // `monospace`
    r'|(https?://[^\s]+)',  // URL
  );

  int lastEnd = 0;

  for (final match in regex.allMatches(text)) {
    // Add text before this match
    if (match.start > lastEnd) {
      spans.add(TextSpan(text: text.substring(lastEnd, match.start), style: base));
    }

    if (match.group(2) != null) {
      // Bold
      spans.add(TextSpan(
        text: match.group(2),
        style: base.copyWith(fontWeight: FontWeight.bold),
      ));
    } else if (match.group(4) != null) {
      // Italic
      spans.add(TextSpan(
        text: match.group(4),
        style: base.copyWith(fontStyle: FontStyle.italic),
      ));
    } else if (match.group(6) != null) {
      // Strikethrough
      spans.add(TextSpan(
        text: match.group(6),
        style: base.copyWith(decoration: TextDecoration.lineThrough),
      ));
    } else if (match.group(8) != null) {
      // Inline code
      spans.add(TextSpan(
        text: match.group(8),
        style: base.copyWith(
          fontFamily: 'monospace',
          fontSize: (base.fontSize ?? 15) - 1,
          backgroundColor: Colors.black.withValues(alpha: 0.08),
          letterSpacing: 0,
        ),
      ));
    } else if (match.group(9) != null) {
      // URL link: WhatsApp-style teal + tap to open externally.
      spans.add(TextSpan(
        text: match.group(9),
        style: base.copyWith(
          color: linkColor ?? const Color(0xFF34B7F1),
          decoration: TextDecoration.underline,
        ),
        recognizer: links.forUrl(match.group(9)!, _openLink),
      ));
    }

    lastEnd = match.end;
  }

  // Remaining text after last match
  if (lastEnd < text.length) {
    spans.add(TextSpan(text: text.substring(lastEnd), style: base));
  }

  if (spans.isEmpty) {
    spans.add(TextSpan(text: text, style: base));
  }

  return spans;
}

class _QuoteLine extends StatelessWidget {
  const _QuoteLine({
    required this.text,
    required this.base,
    this.linkColor,
    required this.links,
  });
  final String text;
  final TextStyle base;
  final Color? linkColor;
  final _LinkManager links;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: isDark ? const Color(0xFF00A884) : const Color(0xFF25D366),
            width: 3,
          ),
        ),
        color: isDark
            ? Colors.black.withValues(alpha: 0.15)
            : Colors.black.withValues(alpha: 0.04),
      ),
      child: Text.rich(
        TextSpan(
          children: _parseInline(
            text,
            base.copyWith(
              fontStyle: FontStyle.italic,
              color: base.color?.withValues(alpha: 0.8),
            ),
            linkColor,
            links,
          ),
        ),
      ),
    );
  }
}

class _BulletLine extends StatelessWidget {
  const _BulletLine({
    required this.text,
    required this.base,
    this.linkColor,
    required this.links,
  });
  final String text;
  final TextStyle base;
  final Color? linkColor;
  final _LinkManager links;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, top: 1, bottom: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('• ', style: base.copyWith(fontWeight: FontWeight.bold)),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: _parseInline(text, base, linkColor, links),
                ),
              ),
            ),
          ],
        ),
      );
}

class _NumberedLine extends StatelessWidget {
  const _NumberedLine({
    required this.number,
    required this.text,
    required this.base,
    this.linkColor,
    required this.links,
  });
  final String number;
  final String text;
  final TextStyle base;
  final Color? linkColor;
  final _LinkManager links;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, top: 1, bottom: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$number. ', style: base.copyWith(fontWeight: FontWeight.w600)),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: _parseInline(text, base, linkColor, links),
                ),
              ),
            ),
          ],
        ),
      );
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A2228) : const Color(0xFFF0F2F5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF2A3942) : const Color(0xFFD1D7DB),
        ),
      ),
      child: SelectableText(
        code,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: isDark ? const Color(0xFFE9EDEF) : const Color(0xFF111B21),
          height: 1.4,
        ),
      ),
    );
  }
}
