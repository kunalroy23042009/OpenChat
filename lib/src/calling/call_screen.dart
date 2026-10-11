import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import 'call_service.dart';

enum CallType { voice, video }

enum CallState { initiating, ringing, connected, reconnecting, ended }

class ActiveCallSession {
  ActiveCallSession({
    required this.callId,
    required this.peerUsername,
    required this.peerDisplayName,
    required this.type,
    CallState initialState = CallState.initiating,
  }) : state = initialState;

  final String callId;
  final String peerUsername;
  final String peerDisplayName;
  final CallType type;
  CallState state;
  bool isMuted = false;
  bool isVideoEnabled = true;
  bool isSpeakerOn = true;
  bool isFrontCamera = true;
  int durationSeconds = 0;
}

/// Live call screen driven by [CallService]. Media flows phone <-> LiveKit
/// SFU; signaling (ring/accept/decline) flows over Supabase. A null service
/// renders an honest preview for demo/group entry points.
class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.session,
    required this.onEndCall,
    this.service,
  });

  final ActiveCallSession session;
  final VoidCallback onEndCall;
  final CallService? service;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.service?.addListener(_onService);
    _syncState(initial: true);
  }

  void _onService() {
    if (!mounted) return;
    setState(() => _syncState());
  }

  void _syncState({bool initial = false}) {
    final service = widget.service;
    if (service == null) return;
    final live = service.state;
    final mapped = switch (live) {
      LiveCallState.joining || LiveCallState.idle => CallState.initiating,
      LiveCallState.ringing => CallState.ringing,
      LiveCallState.connected => CallState.connected,
      LiveCallState.reconnecting => CallState.reconnecting,
      LiveCallState.ended || LiveCallState.failed => CallState.ended,
    };
    if (widget.session.state != CallState.connected &&
        mapped == CallState.connected) {
      _startTimer();
    }
    widget.session.state = mapped;
    widget.session.isMuted = service.muted;
    widget.session.isVideoEnabled = !service.videoOff;
    widget.session.isSpeakerOn = service.speakerOn;
    widget.session.isFrontCamera = service.frontCamera;
    if (!initial && mapped == CallState.ended) {
      widget.onEndCall();
    }
  }

  void _startTimer() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => widget.session.durationSeconds++);
    });
  }

  @override
  void dispose() {
    widget.service?.removeListener(_onService);
    _timer?.cancel();
    super.dispose();
  }

  String _formatDuration(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    if (service == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.call_outlined,
                  color: Colors.white54,
                  size: 56,
                ),
                const SizedBox(height: 16),
                Text(
                  widget.session.peerDisplayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Real voice and video calls start from an encrypted chat with a connected contact.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: widget.onEndCall,
                  child: const Text('Back'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final failed = service.state == LiveCallState.failed;
    final showVideo =
        widget.session.type == CallType.video &&
        service.state == LiveCallState.connected;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: showVideo
                  ? _buildVideoView()
                  : _buildVoiceAvatarView(),
            ),

            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(
                          0xFF10B981,
                        ).withValues(alpha: 0.5),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock_outline,
                          color: Color(0xFF10B981),
                          size: 14,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'End-to-End Encrypted',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.session.peerDisplayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    failed
                        ? (service.error ?? 'Call failed')
                        : _getCallStateText(),
                    style: TextStyle(
                      color: widget.session.state == CallState.connected
                          ? const Color(0xFF34D399)
                          : Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),

            Positioned(
              bottom: 24,
              left: 24,
              right: 24,
              child: _buildCallControls(failed),
            ),
          ],
        ),
      ),
    );
  }

  String _getCallStateText() {
    switch (widget.session.state) {
      case CallState.initiating:
        return 'Connecting...';
      case CallState.ringing:
        return 'Ringing...';
      case CallState.connected:
        return _formatDuration(widget.session.durationSeconds);
      case CallState.reconnecting:
        return 'Reconnecting...';
      case CallState.ended:
        return 'Call Ended';
    }
  }

  Widget _buildVoiceAvatarView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 60,
            backgroundColor: const Color(0xFF245CDB),
            child: Text(
              widget.session.peerDisplayName.isNotEmpty
                  ? widget.session.peerDisplayName[0].toUpperCase()
                  : '?',
              style: const TextStyle(
                fontSize: 48,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '@${widget.session.peerUsername}',
            style: const TextStyle(color: Colors.white60, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoView() {
    final service = widget.service;
    final remote = service?.remoteVideo;
    final local = service?.localVideo;
    return Stack(
      children: [
        Container(
          color: const Color(0xFF1E293B),
          child: remote == null
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.videocam_outlined,
                        size: 64,
                        color: Colors.white38,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Waiting for video…',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                )
              : VideoTrackRenderer(remote),
        ),

        if (local != null)
          Positioned(
            top: 80,
            right: 16,
            width: 100,
            height: 150,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white30, width: 2),
              ),
              clipBehavior: Clip.antiAlias,
              child: VideoTrackRenderer(local),
            ),
          ),
      ],
    );
  }

  Widget _buildCallControls(bool failed) {
    final service = widget.service;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(32),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: Icon(
              widget.session.isMuted ? Icons.mic_off : Icons.mic,
              color: widget.session.isMuted ? Colors.redAccent : Colors.white,
            ),
            onPressed: failed
                ? null
                : () => service?.toggleMute(),
          ),
          if (widget.session.type == CallType.video)
            IconButton(
              icon: const Icon(Icons.flip_camera_ios_outlined, color: Colors.white),
              onPressed: failed
                  ? null
                  : () => service?.switchCamera(),
            ),
          IconButton(
            icon: Icon(
              widget.session.isSpeakerOn
                  ? Icons.volume_up
                  : Icons.volume_off,
              color: widget.session.isSpeakerOn
                  ? Colors.white
                  : Colors.white38,
            ),
            onPressed: failed
                ? null
                : () => service?.toggleSpeaker(),
          ),
          FloatingActionButton(
            heroTag: 'end_call_fab',
            backgroundColor: Colors.redAccent,
            onPressed: widget.onEndCall,
            child: const Icon(Icons.call_end, color: Colors.white),
          ),
        ],
      ),
    );
  }
}
