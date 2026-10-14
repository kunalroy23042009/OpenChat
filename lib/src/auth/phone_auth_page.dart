import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'phone_auth.dart';

/// WhatsApp-style phone login: country + number, then the SMS code.
/// Styling follows the OpenChat brand blue; layout mirrors WhatsApp's
/// verify-number flow (title, helper, boxed inputs, full-width action).
class PhoneAuthPage extends StatefulWidget {
  const PhoneAuthPage({super.key, required this.client, this.onSuccess});
  final SupabaseClient client;
  final VoidCallback? onSuccess;

  @override
  State<PhoneAuthPage> createState() => _PhoneAuthPageState();
}

class _PhoneAuthPageState extends State<PhoneAuthPage> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  String _selectedCountryCode = '+91';
  bool _otpSent = false;
  bool _busy = false;
  String? _errorMessage;
  String? _infoMessage;
  int _resendIn = 0;
  Timer? _resendTimer;
  PhoneAuthService? _service;

  static const _countries = [
    ('India', '+91'),
    ('United States / Canada', '+1'),
    ('United Kingdom', '+44'),
    ('Germany', '+49'),
    ('France', '+33'),
    ('Australia', '+61'),
    ('Japan', '+81'),
    ('Brazil', '+55'),
  ];

  String get _fullNumber =>
      '$_selectedCountryCode${_phoneController.text.trim()}';

  @override
  void dispose() {
    _resendTimer?.cancel();
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  void _lateCodeArrivedFor(PhoneAuthService service) {
    // A slow start (reCAPTCHA fallback) delivered the code after the
    // wait already gave up: advance instead of stranding the user.
    // Ignores callbacks from superseded attempts (e.g. after Resend).
    if (!mounted || !identical(_service, service) || _otpSent) return;
    if (!service.codeReady) return;
    setState(() {
      _otpSent = true;
      _errorMessage = null;
      _infoMessage = 'SMS verification code sent to $_fullNumber';
    });
    _startResendCooldown();
  }

  void _autoVerifiedFor(PhoneAuthService service, bool ok) {
    if (!mounted || !identical(_service, service)) return;
    if (ok) {
      widget.onSuccess?.call();
      Navigator.of(context).pop();
    } else {
      setState(
        () => _errorMessage = 'Automatic verification failed. Enter the SMS code.',
      );
    }
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendIn = 30);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendIn <= 1) {
        timer.cancel();
        setState(() => _resendIn = 0);
      } else {
        setState(() => _resendIn--);
      }
    });
  }

  Future<void> _handleSendOtp() async {
    final fullNumber = _fullNumber;
    setState(() {
      _busy = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    try {
      final service = PhoneAuthService(widget.client);
      service.onAutoVerified = (ok) => _autoVerifiedFor(service, ok);
      service.onCodeSent = () => _lateCodeArrivedFor(service);
      _service = service;
      await service.sendOtp(fullNumber);
      if (!mounted) return;
      if (!service.codeReady) {
        // Still listening in the background: a late codeSent advances the
        // UI via onCodeSent. Don't dead-end the user here.
        setState(
          () => _infoMessage =
              'Still contacting the verification service… you will advance automatically when the code arrives, or tap Resend code.',
        );
        return;
      }
      setState(() {
        _otpSent = true;
        _infoMessage = 'SMS verification code sent to $fullNumber';
      });
      _startResendCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e is AuthException
            ? e.message
            : 'Could not send verification SMS. Check your connection and try again.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleVerifyOtp() async {
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final service = _service ?? PhoneAuthService(widget.client);
      final verified = await service.verifyOtp(
        _fullNumber,
        _otpController.text,
      );
      if (!mounted) return;
      if (verified) {
        widget.onSuccess?.call();
        Navigator.of(context).pop();
      } else {
        setState(() => _errorMessage = 'Invalid code. Check the SMS and try again.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e is AuthException ? e.message : 'Verification failed.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Verify phone number')),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: _otpSent ? _otpStep() : _numberStep(),
          ),
        ),
      ),
    ),
  );

  Widget _numberStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Enter your phone number',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'OpenChat will send an SMS message to verify your phone number.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Color(0xFF66748A), height: 1.4),
      ),
      const SizedBox(height: 28),
      InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Country',
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 12),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _selectedCountryCode,
            isExpanded: true,
            items: [
              for (final country in _countries)
                DropdownMenuItem<String>(
                  value: country.$2,
                  child: Text('${country.$1} (${country.$2})'),
                ),
            ],
            onChanged: (val) {
              if (val != null) setState(() => _selectedCountryCode = val);
            },
          ),
        ),
      ),
      const SizedBox(height: 16),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 17),
            decoration: BoxDecoration(
              border: Border.all(color: Color(0xFF9AA5B5)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _selectedCountryCode,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone number',
                hintText: '98765 43210',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        'Carrier SMS charges may apply.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _handleSendOtp,
        style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('Next'),
      ),
      ..._feedback(),
    ],
  );

  Widget _otpStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Enter the SMS code',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(
        'Sent to $_fullNumber. Waiting for the SMS — it usually arrives within a minute.',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFF66748A), height: 1.4),
      ),
      const SizedBox(height: 28),
      TextField(
        controller: _otpController,
        keyboardType: TextInputType.number,
        maxLength: 6,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 28,
          letterSpacing: 10,
          fontWeight: FontWeight.w700,
        ),
        decoration: const InputDecoration(
          hintText: '– – – – – –',
          hintStyle: TextStyle(letterSpacing: 10, color: Color(0xFF9AA5B5)),
          border: OutlineInputBorder(),
          counterText: '',
        ),
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _handleVerifyOtp,
        style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('Verify & Sign In'),
      ),
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _otpSent = false;
                    _errorMessage = null;
                    _infoMessage = null;
                  }),
            child: const Text('Wrong number?'),
          ),
          TextButton(
            onPressed: _busy || _resendIn > 0 ? null : _handleSendOtp,
            child: Text(
              _resendIn > 0 ? 'Resend in $_resendIn s' : 'Resend code',
            ),
          ),
        ],
      ),
      ..._feedback(),
    ],
  );

  List<Widget> _feedback() => [
    if (_errorMessage != null) ...[
      const SizedBox(height: 16),
      Text(
        _errorMessage!,
        style: const TextStyle(color: Colors.red, fontSize: 13, height: 1.4),
        textAlign: TextAlign.center,
      ),
    ],
    if (_infoMessage != null) ...[
      const SizedBox(height: 16),
      Text(
        _infoMessage!,
        style: const TextStyle(
          color: Color(0xFF0A7B3E),
          fontSize: 13,
          height: 1.4,
        ),
        textAlign: TextAlign.center,
      ),
    ],
  ];
}
