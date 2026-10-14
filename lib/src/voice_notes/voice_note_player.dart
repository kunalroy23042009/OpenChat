import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

String voiceTime(Duration d) => '${max(0, d.inSeconds) ~/ 60}:${(max(0, d.inSeconds) % 60).toString().padLeft(2, '0')}';

/// Reduce measured microphone amplitudes, retaining peaks rather than
/// generating decorative/fake waveform data.
List<double> compactWaveform(List<double> samples, {int bars = 48}) {
  if (samples.length <= bars) return List.of(samples);
  return List.generate(bars, (i) => samples.sublist(i * samples.length ~/ bars,
      (i + 1) * samples.length ~/ bars).reduce(max));
}

class VoiceWavePainter extends CustomPainter {
  VoiceWavePainter(this.samples, this.color, this.progress);
  final List<double> samples;
  final Color color;
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final step = size.width / samples.length;
    for (var i = 0; i < samples.length; i++) {
      final height = max(2.0, samples[i].clamp(0, 1) * size.height);
      final paint = Paint()..color = i / samples.length <= progress ? color : color.withValues(alpha: .3)
        ..strokeWidth = min(3.0, step * .65)..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(step * (i + .5), (size.height - height) / 2), Offset(step * (i + .5), (size.height + height) / 2), paint);
    }
  }
  @override
  bool shouldRepaint(VoiceWavePainter old) => old.samples != samples || old.progress != progress || old.color != color;
}

class VoiceNotePlayer extends StatefulWidget {
  const VoiceNotePlayer({super.key, required this.audioFile, required this.duration, required this.mine, this.waveform = const []});
  final File audioFile;
  final Duration duration;
  final bool mine;
  final List<double> waveform;
  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;
  Duration _position = Duration.zero;
  late Duration _duration = widget.duration;
  bool _ready = false, _playing = false;
  double _speed = 1;
  String? _error;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final duration = await _player.setFilePath(widget.audioFile.path);
      if (!mounted) return;
      _duration = duration ?? widget.duration;
      _positionSub = _player.positionStream.listen((p) { if (mounted) setState(() => _position = p); });
      _stateSub = _player.playerStateStream.listen((s) {
        if (!mounted) return;
        setState(() => _playing = s.playing && s.processingState != ProcessingState.completed);
        if (s.processingState == ProcessingState.completed) unawaited(_player.pause());
      });
      setState(() => _ready = true);
    } catch (_) { if (mounted) setState(() => _error = 'Audio could not be opened.'); }
  }
  Future<void> _toggle() async {
    try {
      if (_playing) { await _player.pause(); }
      else {
        if (_player.processingState == ProcessingState.completed) await _player.seek(Duration.zero);
        await _player.play();
      }
    } catch (_) { if (mounted) setState(() => _error = 'Playback failed.'); }
  }
  @override
  void dispose() { _positionSub?.cancel(); _stateSub?.cancel(); _player.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text(_error!);
    if (!_ready) return const SizedBox(height: 48, child: Center(child: CircularProgressIndicator()));
    final total = max(1, _duration.inMilliseconds);
    final progress = (_position.inMilliseconds / total).clamp(0.0, 1.0);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        IconButton(tooltip: _playing ? 'Pause voice note' : 'Play voice note', onPressed: _toggle, icon: Icon(_playing ? Icons.pause : Icons.play_arrow)),
        Expanded(child: SizedBox(height: 36, child: CustomPaint(painter: VoiceWavePainter(widget.waveform, Theme.of(context).colorScheme.primary, progress)))),
        TextButton(onPressed: () async {
          final next = _speed == 1 ? 1.5 : _speed == 1.5 ? 2.0 : 1.0;
          await _player.setSpeed(next);
          if (mounted) setState(() => _speed = next);
        }, child: Text('${_speed}x')),
      ]),
      Row(children: [
        Expanded(child: Slider(value: progress, onChanged: (v) => _player.seek(Duration(milliseconds: (v * total).round())))),
        Text(voiceTime(_duration - _position), style: const TextStyle(fontSize: 12)),
      ]),
    ]);
  }
}
