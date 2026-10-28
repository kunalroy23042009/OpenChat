import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Service for generating on-device speech-to-text transcripts for voice notes.
/// Uses platform speech recognition (iOS Speech Framework / Android SpeechRecognizer).
class VoiceTranscriptService {
  VoiceTranscriptService._();
  static final VoiceTranscriptService instance = VoiceTranscriptService._();

  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;
  bool _listening = false;
  String? _lastError;

  /// Initialize the speech recognition engine. Must be called before transcription.
  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      _initialized = await _speech.initialize(
        onError: (e) => _lastError = e.errorMsg,
        onStatus: (s) => debugPrint('Speech status: $s'),
      );
      return _initialized;
    } catch (e) {
      _lastError = e.toString();
      return false;
    }
  }

  /// Get the last error from initialization or transcription.
  String? get lastError => _lastError;

  /// Check if speech recognition is available.
  Future<bool> get isAvailable async {
    if (!_initialized) await initialize();
    return _initialized && await _speech.hasPermission;
  }

  /// Transcribe an audio file to text.
  /// Note: speech_to_text package doesn't support direct file transcription on all platforms.
  /// For production, use platform channels with:
  /// - iOS: SFSpeechRecognizer with SFSpeechURLRecognitionRequest
  /// - Android: SpeechRecognizer with FILE_SOURCE
  /// This method returns null indicating file transcription requires native implementation.
  Future<String?> transcribeFile(String audioPath) async {
    debugPrint('VoiceTranscriptService: File transcription requires native platform channel implementation');
    debugPrint('  iOS: SFSpeechRecognizer with SFSpeechURLRecognitionRequest');
    debugPrint('  Android: SpeechRecognizer with RecognitionListener + FILE_SOURCE');
    return null;
  }

  /// Start live transcription from microphone. Useful for real-time dictation.
  Future<bool> startListening({
    Function(String)? onResult,
    Function(bool)? onListeningChanged,
    String localeId = 'en_US',
  }) async {
    if (_listening) return true;
    if (!_initialized) await initialize();

    _listening = true;
    onListeningChanged?.call(true);
    try {
      await _speech.listen(
        onResult: (result) {
          if (result.finalResult && onResult != null) {
            onResult(result.recognizedWords);
          }
        },
        listenOptions: SpeechListenOptions(
          localeId: localeId,
          listenMode: ListenMode.dictation,
          partialResults: true,
        ),
      );
      return true;
    } catch (e) {
      _listening = false;
      onListeningChanged?.call(false);
      return false;
    }
  }

  /// Stop live transcription.
  Future<void> stopListening() async {
    if (!_listening) return;
    await _speech.stop();
    _listening = false;
  }

  /// Cancel any ongoing transcription.
  Future<void> cancel() async {
    await _speech.cancel();
    _listening = false;
  }

  /// Get available locales for speech recognition.
  Future<List<LocaleName>> getLocales() async {
    if (!_initialized) await initialize();
    return _speech.locales();
  }

  void dispose() {
    _speech.stop();
    _speech.cancel();
  }
}

/// Extension to transcribe voice notes in chat context.
extension VoiceNoteTranscriptExt on VoiceTranscriptService {
  /// Generate transcript for a voice note and update the message.
  /// This is a best-effort client-side feature; transcripts are not E2EE.
  Future<String?> generateAndStoreTranscript({
    required String audioPath,
    required Function(String) onTranscriptReady,
  }) async {
    final transcript = await transcribeFile(audioPath);
    if (transcript != null && transcript.isNotEmpty) {
      onTranscriptReady(transcript);
    }
    return transcript;
  }
}