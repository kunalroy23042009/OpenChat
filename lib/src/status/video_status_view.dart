import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Inline playback for a status video — a local draft file [path] or a
/// cloud signed URL [url]. Loops silently until the viewer closes it.
class VideoStatusView extends StatefulWidget {
  const VideoStatusView({super.key, this.path, this.url})
    : assert(
        (path == null) != (url == null),
        'Provide exactly one of path or url',
      );
  final String? path;
  final String? url;
  @override
  State<VideoStatusView> createState() => _VideoStatusViewState();
}

class _VideoStatusViewState extends State<VideoStatusView> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    final controller = widget.path != null
        ? VideoPlayerController.file(File(widget.path!))
        : VideoPlayerController.networkUrl(Uri.parse(widget.url!));
    controller.setLooping(true);
    controller.initialize().then((_) async {
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.play();
    }).catchError((_) {
      if (mounted) setState(() => _controller = controller);
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    return GestureDetector(
      onTap: () => setState(
        () => controller.value.isPlaying
            ? controller.pause()
            : controller.play(),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}
