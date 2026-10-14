import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../chat_store.dart';
import '../security/secure_display.dart';
import 'chat_media.dart';
import 'media_message.dart';
import 'video_player_screen.dart';

class ViewOnceScreen extends StatefulWidget {
  const ViewOnceScreen({super.key, required this.body, required this.media, required this.store,
    required this.account, required this.peer, required this.messageRef});
  final MediaBody body;
  final ChatMedia media;
  final ChatStore store;
  final String account, peer, messageRef;
  @override
  State<ViewOnceScreen> createState() => _ViewOnceScreenState();
}
class _ViewOnceScreenState extends State<ViewOnceScreen> with WidgetsBindingObserver {
  Uint8List? _bytes;
  bool _protected = false;
  String? _error;
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); _load(); }
  Future<void> _load() async {
    try {
      await SecureDisplay.acquire();
      if (!mounted) { await SecureDisplay.release(); return; }
      _protected = true;
      final body = widget.body;
      if (!body.isSealed) throw StateError('Missing key');
      final bytes = await widget.media.downloadSealed(body.path!, body.key!, body.nonce!);
      if (!mounted) { bytes.fillRange(0, bytes.length, 0); return; }
      final claimed = await widget.store.consumeViewOnce(widget.account, widget.peer, widget.messageRef);
      if (!claimed || !mounted) {
        bytes.fillRange(0, bytes.length, 0);
        if (mounted) setState(() => _error = 'This media has already been opened.');
        return;
      }
      setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open protected media. Screenshot protection and a connection are required.');
    }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) Navigator.of(context).pop();
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Plaintext only ever lives in this buffer; wipe it on close.
    _bytes?.fillRange(0, _bytes!.length, 0);
    _bytes = null;
    if (_protected) unawaited(SecureDisplay.release());
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    if (_bytes != null && widget.body.isVideo) return SealedVideoScreen(bytes: _bytes!, caption: 'View once');
    return Scaffold(backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('View once')),
      body: Center(child: _error != null ? Text(_error!, style: const TextStyle(color: Colors.white)) :
        _bytes == null ? const CircularProgressIndicator() : InteractiveViewer(child: Image.memory(_bytes!))));
  }
}
