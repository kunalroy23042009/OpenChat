import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../media/chat_media.dart';
import '../media/media_message.dart';
import '../widgets/status_ticks.dart';
import 'voice_note_player.dart';

class VoiceNoteBubble extends StatefulWidget {
  const VoiceNoteBubble({super.key, required this.media, required this.body, required this.mine, required this.time, this.status = 'sent'});
  final ChatMedia media;
  final MediaBody body;
  final bool mine;
  final DateTime time;
  final String status;
  @override
  State<VoiceNoteBubble> createState() => _VoiceNoteBubbleState();
}

class _VoiceNoteBubbleState extends State<VoiceNoteBubble> {
  File? _file;
  bool _loading = false;
  String? _error;
  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    File? file;
    try {
      final body = widget.body;
      if (!body.isSealed) throw StateError('Missing audio key');
      final bytes = await widget.media.downloadSealed(body.path!, body.key!, body.nonce!);
      final dir = await getTemporaryDirectory();
      file = File('${dir.path}/oc-audio-${DateTime.now().microsecondsSinceEpoch}.m4a');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) { await file.delete(); return; }
      setState(() => _file = file);
    } catch (_) {
      if (file != null && await file.exists()) await file.delete();
      if (mounted) setState(() => _error = 'Could not download audio. Tap to retry.');
    } finally { if (mounted) setState(() => _loading = false); }
  }
  @override
  void dispose() { _file?.delete().ignore(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Align(alignment: widget.mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(width: 300, margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(18)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (_file != null) VoiceNotePlayer(audioFile: _file!, duration: Duration(seconds: widget.body.durationSec), mine: widget.mine, waveform: widget.body.waveform)
        else if (_loading) const LinearProgressIndicator()
        else TextButton.icon(onPressed: _load, icon: const Icon(Icons.play_circle_outline), label: Text(_error ?? 'Voice note • ${voiceTime(Duration(seconds: widget.body.durationSec))}')),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${widget.time.hour.toString().padLeft(2, '0')}:${widget.time.minute.toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 11)),
          if (widget.mine) MessageStatusTicks(state: switch(widget.status) { 'read' => MessageDeliveryState.read, 'delivered' => MessageDeliveryState.delivered, _ => MessageDeliveryState.sent }),
        ]),
      ])),
  );
}
