import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'phone_auth.dart';

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
  String _selectedCountryCode = '+1';
  bool _otpSent = false;
  bool _busy = false;
  String? _errorMessage;
  String? _infoMessage;

  final List<Map<String, String>> _countryCodes = const [
    {'country': 'United States / Canada', 'code': '+1'},
    {'country': 'United Kingdom', 'code': '+44'},
    {'country': 'India', 'code': '+91'},
    {'country': 'Germany', 'code': '+49'},
    {'country': 'France', 'code': '+33'},
    {'country': 'Australia', 'code': '+61'},
    {'country': 'Japan', 'code': '+81'},
    {'country': 'Brazil', 'code': '+55'},
  ];

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _handleSendOtp() async {
    final fullNumber = '$_selectedCountryCode${_phoneController.text.trim()}';
    setState(() {
      _busy = true;
      _errorMessage = null;
      _infoMessage = null;
    });

    try {
      final service = PhoneAuthService(widget.client);
      await service.sendOtp(fullNumber);
      if (!mounted) return;
      setState(() {
        _otpSent = true;
        _infoMessage = 'SMS verification code sent to $fullNumber';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e is AuthException ? e.message : 'Could not send verification SMS. Verify provider config.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleVerifyOtp() async {
    final fullNumber = '$_selectedCountryCode${_phoneController.text.trim()}';
    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      final service = PhoneAuthService(widget.client);
      final verified = await service.verifyOtp(fullNumber, _otpController.text);
      if (!mounted) return;
      if (verified) {
        widget.onSuccess?.call();
        Navigator.of(context).pop();
      } else {
        setState(() => _errorMessage = 'Invalid OTP code. Please try again.');
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Phone Number Verification')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.phone_android_rounded,
                  size: 64,
                  color: Color(0xFF245CDB),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Enter your phone number',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Open Chat will send an SMS message to verify your phone number.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 32),
                if (!_otpSent) ...[
                  Row(
                    children: [
                      DropdownButton<String>(
                        value: _selectedCountryCode,
                        items: _countryCodes.map((c) {
                          return DropdownMenuItem<String>(
                            value: c['code'],
                            child: Text('${c['code']} (${c['country']})'),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) setState(() => _selectedCountryCode = val);
                        },
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            hintText: 'Phone number',
                            prefixIcon: Icon(Icons.phone),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _handleSendOtp,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Send SMS Code'),
                  ),
                ] else ...[
                  TextField(
                    controller: _otpController,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      hintText: '123456',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _handleVerifyOtp,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Verify & Sign In'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _otpSent = false),
                    child: const Text('Edit Phone Number'),
                  ),
                ],
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
                if (_infoMessage != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _infoMessage!,
                    style: const TextStyle(color: Color(0xFF10B981), fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
