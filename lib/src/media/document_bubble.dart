import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'document_transfer.dart';
import 'media_message.dart';

class DocumentBubble extends StatefulWidget {
  const DocumentBubble({super.key, required this.body, required this.transfer, required this.mine});
  final MediaBody body;
  final DocumentTransfer transfer;
  final bool mine;
  @override
  State<DocumentBubble> createState() => _DocumentBubbleState();
}
class _DocumentBubbleState extends State<DocumentBubble> {
  TransferControl? _control;
  double _progress = 0;
  String? _error;
  File? _file;
  Future<void> _open() async {
    if (_control != null) return;
    setState(() { _control = TransferControl(); _error = null; });
    try {
      if (_file == null) {
        final dir = await (await getTemporaryDirectory()).createTemp('oc-doc-');
        final file = File('${dir.path}/${DocumentTransfer.safeName(widget.body.fileName)}');
        _file = await widget.transfer.download(widget.body, file, control: _control,
          onProgress: (p) { if (mounted) setState(() => _progress = p); });
      }
      if (!mounted) return;
      final result = await OpenFilex.open(_file!.path);
      if (result.type != ResultType.done && mounted) setState(() => _error = 'No app could open this file.');
    } on TransferCancelled {
      // User cancelled the download; keep the cached state as-is.
    } catch (_) { if (mounted) setState(() => _error = 'Download failed. Tap to retry.'); }
    finally { if (mounted) setState(() => _control = null); }
  }
  @override
  void dispose() {
    _control?.cancelled = true;
    // An external viewer may still be reading it. OS cache cleanup can
    // reclaim this private temporary copy after the viewer has finished.
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => Align(alignment: widget.mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Card(child: SizedBox(width: 300, child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.description_outlined), title: Text(widget.body.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(_error ?? '${(widget.body.byteLength / (1024 * 1024)).toStringAsFixed(2)} MB • Encrypted document'),
        onTap: _control == null ? _open : null,
        trailing: _control == null ? const Icon(Icons.download) : IconButton(tooltip: 'Cancel download', onPressed: () => _control?.cancelled = true, icon: const Icon(Icons.close))),
      if (_control != null) LinearProgressIndicator(value: _progress),
    ]))),
  );
}
