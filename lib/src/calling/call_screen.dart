import 'dart:async';
import 'package:flutter/material.dart';

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

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.session,
    required this.onEndCall,
  });

  final ActiveCallSession session;
  final VoidCallback onEndCall;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.session.state == CallState.initiating ||
        widget.session.state == CallState.ringing) {
      Timer(const Duration(seconds: 3), () {
        if (mounted && widget.session.state != CallState.ended) {
          setState(() {
            widget.session.state = CallState.connected;
          });
          _startTimer();
        }
      });
    } else if (widget.session.state == CallState.connected) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          widget.session.durationSeconds++;
        });
      }
    });
  }

  @override
  void dispose() {
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
    final isVideo = widget.session.type == CallType.video && widget.session.isVideoEnabled;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: isVideo
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
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.5)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_outline, color: Color(0xFF10B981), size: 14),
                        SizedBox(width: 6),
                        Text(
                          'End-to-End Encrypted',
                          style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
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
                    _getCallStateText(),
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
              child: _buildCallControls(),
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
        return 'Reconnecting Signal channel...';
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
              style: const TextStyle(fontSize: 48, color: Colors.white, fontWeight: FontWeight.bold),
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
    return Stack(
      children: [
        Container(
          color: const Color(0xFF1E293B),
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.videocam_outlined, size: 64, color: Colors.white38),
                SizedBox(height: 8),
                Text('E2EE Video Stream Connected', style: TextStyle(color: Colors.white54)),
              ],
            ),
          ),
        ),

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
            child: const Center(
              child: Icon(Icons.person, color: Colors.white54, size: 36),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCallControls() {
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
            onPressed: () {
              setState(() => widget.session.isMuted = !widget.session.isMuted);
            },
          ),
          IconButton(
            icon: Icon(
              widget.session.isVideoEnabled ? Icons.videocam : Icons.videocam_off,
              color: widget.session.isVideoEnabled ? Colors.white : Colors.white38,
            ),
            onPressed: () {
              setState(() => widget.session.isVideoEnabled = !widget.session.isVideoEnabled);
            },
          ),
          IconButton(
            icon: Icon(
              widget.session.isSpeakerOn ? Icons.volume_up : Icons.volume_off,
              color: widget.session.isSpeakerOn ? Colors.white : Colors.white38,
            ),
            onPressed: () {
              setState(() => widget.session.isSpeakerOn = !widget.session.isSpeakerOn);
            },
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
