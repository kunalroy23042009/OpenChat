import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// Fullscreen sealed-video playback. Plaintext is staged to a temp file
/// only for the player (video_player needs a file) and deleted on exit.
class SealedVideoScreen extends StatefulWidget {
  const SealedVideoScreen({super.key, required this.bytes, this.caption = ''});
  final Uint8List bytes;
  final String caption;
  @override
  State<SealedVideoScreen> createState() => _SealedVideoScreenState();
}

class _SealedVideoScreenState extends State<SealedVideoScreen> {
  VideoPlayerController? _controller;
  File? _temp;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/oc-play-${DateTime.now().microsecondsSinceEpoch}.mp4',
      );
      await file.writeAsBytes(widget.bytes, flush: true);
      _temp = file;
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      controller.setLooping(true);
      if (!mounted) {
        await controller.dispose();
        if (await file.exists()) await file.delete();
        return;
      }
      setState(() => _controller = controller);
      await controller.play();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not play this video.');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _temp?.delete().ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: widget.caption.isEmpty
            ? null
            : Text(
                widget.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
      ),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white70))
            : controller == null
            ? const CircularProgressIndicator()
            : GestureDetector(
                onTap: () => setState(
                  () => controller.value.isPlaying
                      ? controller.pause()
                      : controller.play(),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: controller.value.aspectRatio,
                      child: VideoPlayer(controller),
                    ),
                    if (!controller.value.isPlaying)
                      const Icon(
                        Icons.play_circle_filled,
                        color: Colors.white70,
                        size: 72,
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
