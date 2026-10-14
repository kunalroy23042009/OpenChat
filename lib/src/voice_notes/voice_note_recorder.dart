import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'voice_note_player.dart';

/// Holds raw recordings only until send/discard. Permissions are requested
/// on interaction, never when a chat is opened.
class VoiceNoteRecorder extends StatefulWidget {
  const VoiceNoteRecorder({super.key, required this.onRecorded,
    this.maxDuration = const Duration(minutes: 2)});
  final Future<void> Function(File file, Duration duration, List<double> waveform) onRecorded;
  final Duration maxDuration;
  @override
  State<VoiceNoteRecorder> createState() => _VoiceNoteRecorderState();
}

class _VoiceNoteRecorderState extends State<VoiceNoteRecorder> with WidgetsBindingObserver {
  final _recorder = AudioRecorder();
  final _clock = Stopwatch();
  final _samples = <double>[];
  StreamSubscription<Amplitude>? _amplitudes;
  Timer? _timer;
  Future<void>? _starting;
  File? _file;
  bool _recording = false, _paused = false, _locked = false;
  bool _released = false, _cancelled = false, _busy = false, _sending = false;
  String? _error;

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _recording && !_busy) {
      unawaited(_finish()); // Keep a preview, never send on interruption.
    }
  }

  void _start() {
    if (_busy || _recording || _file != null) return;
    _released = false;
    _cancelled = false;
    _starting = _begin();
  }

  Future<void> _begin() async {
    setState(() { _busy = true; _error = null; });
    try {
      if (!await _recorder.hasPermission()) throw StateError('Allow microphone access to record a voice note.');
      if (!mounted || _cancelled || _released) return;
      final dir = await getTemporaryDirectory();
      _file = File('${dir.path}/oc-voice-${DateTime.now().microsecondsSinceEpoch}.m4a');
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc,
        bitRate: 64000, sampleRate: 44100, numChannels: 1), path: _file!.path);
      if (!mounted || _cancelled) { await _recorder.cancel(); return; }
      _clock..reset()..start();
      _samples.clear();
      _recording = true;
      _amplitudes = _recorder.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((amplitude) {
        if (!mounted || !_recording || _paused) return;
        _samples.add(pow(10, amplitude.current.clamp(-60, 0) / 20).toDouble());
        setState(() {});
      });
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() {});
        if (_clock.elapsed >= widget.maxDuration) unawaited(_finish());
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is StateError ? e.message.toString() : 'Could not start recording.');
    } finally {
      _busy = false;
      if (mounted) setState(() {});
      if (_released && _recording && !_locked) await _finish();
    }
  }

  Future<void> _finish() async {
    _released = true;
    if (_busy || !_recording) return;
    setState(() => _busy = true);
    _clock.stop();
    _timer?.cancel();
    await _amplitudes?.cancel();
    try {
      final path = await _recorder.stop();
      if (path == null || _clock.elapsedMilliseconds < 400) {
        await _file?.delete().catchError((_) => _file!);
        _file = null;
        _error = 'Hold a little longer to record a voice note.';
      }
    } catch (_) { _error = 'Could not finish the recording.'; }
    _recording = false;
    _paused = false;
    _locked = false;
    _busy = false;
    if (mounted) setState(() {});
  }

  Future<void> _pause() async {
    if (_busy || !_recording) return;
    setState(() => _busy = true);
    try {
      if (_paused) { await _recorder.resume(); _clock.start(); }
      else { await _recorder.pause(); _clock.stop(); }
      _paused = !_paused;
    } catch (_) { _error = 'Could not change recording state.'; }
    _busy = false;
    if (mounted) setState(() {});
  }

  Future<void> _discard() async {
    _cancelled = true;
    await _starting;
    _timer?.cancel();
    await _amplitudes?.cancel();
    await _recorder.cancel();
    final file = _file;
    if (file != null && await file.exists()) await file.delete();
    _file = null;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _send() async {
    final file = _file;
    if (file == null || _recording || _sending) return;
    setState(() { _sending = true; _error = null; });
    try {
      await widget.onRecorded(file, _clock.elapsed, compactWaveform(_samples));
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() { _sending = false; _error = 'Not sent. Your recording is ready to retry.'; });
    }
  }

  Future<void> _cleanup() async {
    await _starting;
    try {
      await _amplitudes?.cancel();
      await _recorder.cancel();
      await _recorder.dispose();
      if (_file != null && await _file!.exists()) await _file!.delete();
    } catch (_) {}
  }

  @override
  void dispose() {
    _cancelled = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_cleanup());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_sending,
    child: SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_recording ? (_locked ? 'Hands-free recording' : 'Release to preview • swipe up to lock') : 'Voice note', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_file != null && !_recording && !_busy)
          VoiceNotePlayer(audioFile: _file!, duration: _clock.elapsed, mine: true, waveform: compactWaveform(_samples)),
        if (_recording) ...[
          SizedBox(height: 48, width: double.infinity, child: CustomPaint(painter: VoiceWavePainter(compactWaveform(_samples), Theme.of(context).colorScheme.primary, 1))),
          Text(voiceTime(_clock.elapsed)),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(tooltip: _paused ? 'Resume recording' : 'Pause recording', onPressed: _busy ? null : _pause, icon: Icon(_paused ? Icons.play_arrow : Icons.pause)),
            IconButton(tooltip: 'Stop and preview', onPressed: _busy ? null : _finish, icon: const Icon(Icons.stop)),
          ]),
        ],
        // Keep the gesture recognizer mounted throughout the hold.
        GestureDetector(
          onLongPressStart: (_) => _start(),
          onLongPressMoveUpdate: (d) { if (_recording && d.offsetFromOrigin.dy < -50) setState(() => _locked = true); },
          onLongPressEnd: (_) { _released = true; if (!_locked) unawaited(_finish()); },
          onLongPressCancel: () { _released = true; if (_recording && !_locked) unawaited(_discard()); },
          child: Semantics(label: 'Hold to record voice note', button: true, child: Padding(
            padding: const EdgeInsets.all(12), child: Icon(_locked ? Icons.lock : Icons.mic, size: 40, color: _recording ? Colors.red : Theme.of(context).colorScheme.primary))),
        ),
        if (_file == null && !_busy) const Text('Hold the microphone to record (up to 2 minutes).'),
        if (_busy || _sending) const LinearProgressIndicator(),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: _sending ? null : _discard, child: const Text('Discard')),
          FilledButton(onPressed: _file != null && !_recording && !_busy && !_sending ? _send : null, child: const Text('Send')),
        ]),
      ],
    ))),
  );
}
