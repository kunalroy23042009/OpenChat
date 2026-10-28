import 'dart:async';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'avatar_sync.dart';
import 'contacts_repository.dart';
import 'auth/password_auth.dart';
import 'auth/password_field.dart';
import 'auth/phone_auth.dart';
import 'google_sign_in.dart';
import 'local_profile.dart';
import 'recovery_page.dart';

/// First-launch flow: welcome → account → profile setup.
/// Returning users never see this; the flag lives in shared preferences.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.profile,
    required this.preferences,
    this.client,
    this.startupError,
    required this.onDone,
  });
  final LocalProfile profile;
  final SharedPreferences preferences;
  final SupabaseClient? client;
  final String? startupError;
  final VoidCallback onDone;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  int step = 0;

  Future<void> finish() async {
    await widget.preferences.setBool('openchat.onboarding.v1', true);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _WelcomeStep(onContinue: () => setState(() => step = 1)),
      _AccountStep(
        client: widget.client,
        startupError: widget.startupError,
        onSkip: () => setState(() => step = 2),
        onDone: () => setState(() => step = 2),
      ),
      _ProfileStep(
        profile: widget.profile,
        client: widget.client,
        preferences: widget.preferences,
        onDone: finish,
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: KeyedSubtree(key: ValueKey(step), child: pages[step]),
        ),
      ),
    );
  }
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep({required this.onContinue});
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Semantics(
              label: 'OpenChat logo',
              image: true,
              child: Image.asset(
                Theme.of(context).brightness == Brightness.dark
                    ? 'assets/logos/openchat_dove_white.png'
                    : 'assets/logos/openchat_dove.png',
                width: 112,
                height: 112,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 36),
            const Text(
              'Welcome to\nOpenChat',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 44,
                height: 1.1,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.5,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Simple, private messaging with the people who matter. '
              'Your keys stay on your device.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Color(0xFF66748A)),
            ),
            const SizedBox(height: 48),
            FilledButton(
              onPressed: onContinue,
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 56),
              ),
              child: const Text('Agree and continue'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Private by design. Your keys stay on your device, and chats are end-to-end encrypted.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
            ),
          ],
        ),
      ),
    ),
  );
}

class _AccountStep extends StatefulWidget {
  const _AccountStep({
    this.client,
    this.startupError,
    required this.onSkip,
    required this.onDone,
  });
  final SupabaseClient? client;
  final String? startupError;
  final VoidCallback onSkip;
  final VoidCallback onDone;

  @override
  State<_AccountStep> createState() => _AccountStepState();
}

class _AccountStepState extends State<_AccountStep> {
  final email = TextEditingController();
  final password = TextEditingController();
  StreamSubscription<AuthState>? authSubscription;
  bool busy = false;
  String? feedback;

  @override
  void initState() {
    super.initState();
    authSubscription = widget.client?.auth.onAuthStateChange.listen(
      (state) {
        if (state.event == AuthChangeEvent.signedIn &&
            state.session != null &&
            mounted) {
          widget.onDone();
        }
      },
      onError: (Object _) {
        if (mounted) {
          setState(
            () => feedback =
                'Could not refresh your session. Please try signing in again.',
          );
        }
      },
    );
  }

  @override
  void dispose() {
    authSubscription?.cancel();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> authenticate(bool register) async {
    if (busy) return;
    final validation = credentialsValidation(
      email.text,
      password.text,
      register: register,
    );
    if (validation != null) {
      setState(() => feedback = validation);
      return;
    }
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      final signedIn = await PasswordAuth(widget.client!)
          .authenticate(email.text, password.text, register: register);
      if (!mounted) return;
      if (signedIn) {
        widget.onDone();
      } else {
        setState(
          () => feedback =
              'Check your email to confirm your account, then sign in here.',
        );
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => feedback = passwordAuthError(e));
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback =
              'Could not connect. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(32),
        children: [
          const Text(
            'Your account.',
            style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text(
            'Sign in to connect with contacts, or skip and explore the demo first.',
            style: TextStyle(color: Color(0xFF66748A)),
          ),
          const SizedBox(height: 28),
          if (widget.startupError != null) ...[
            Text(widget.startupError!),
            const SizedBox(height: 12),
          ],
          if (widget.client == null) ...[
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No cloud backend is configured in this build, so accounts are unavailable. You can still explore the local demo.',
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: widget.onSkip,
              child: const Text('Continue to profile setup'),
            ),
          ] else ...[
            TextField(
              controller: email,
              enabled: !busy,
              autocorrect: false,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 12),
            PasswordField(
              controller: password,
              enabled: !busy,
              onSubmitted: (_) => authenticate(false),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Use your OpenChat password here. Google passwords work only on Google\'s sign-in page.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => RecoveryPage(client: widget.client!),
                          ),
                        ),
                child: const Text('Forgot password?'),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: busy ? null : () => authenticate(false),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
              ),
              child: Text(busy ? 'Please wait…' : 'Sign in'),
            ),
            TextButton(
              onPressed: busy ? null : () => authenticate(true),
              child: const Text('Create account'),
            ),
            const SizedBox(height: 8),
            GoogleSignInButton(
              client: widget.client!,
              onMessage: (message) {
                if (mounted) setState(() => feedback = message);
              },
            ),
            const SizedBox(height: 8),
            if (feedback != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Semantics(liveRegion: true, child: Text(feedback!)),
              ),
          ],
        ],
      ),
    );
  }
}

class _ProfileStep extends StatefulWidget {
  const _ProfileStep({
    super.key,
    required this.profile,
    required this.client,
    required this.preferences,
    required this.onDone,
  });
  final LocalProfile profile;
  final SupabaseClient? client;
  final SharedPreferences preferences;
  final VoidCallback onDone;

  @override
  State<_ProfileStep> createState() => _ProfileStepState();
}

class _ProfileStepState extends State<_ProfileStep> {
  final name = TextEditingController();
  final about = TextEditingController();
  String? error;
  bool busy = false;
  html.File? _pickedFile;

  @override
  void initState() {
    super.initState();
    name.text = widget.profile.name;
    about.text = widget.profile.about;
  }

  @override
  void dispose() {
    name.dispose();
    about.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final input = html.FileUploadInputElement()..accept = 'image/*';
    input.click();
    await input.onChange.first;
    if (input.files!.isNotEmpty) {
      final file = input.files!.first;
      setState(() => _pickedFile = file);
      await widget.profile.setAvatar(file);
    }
  }

  Future<void> _submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.profile.save(name: name.text, about: about.text);
      if (widget.client != null && widget.client!.auth.currentUser != null) {
        await widget.client!.rpc('save_profile', params: {
          'p_display_name': name.text.trim(),
          'p_username': name.text.trim().toLowerCase().replaceAll(' ', '_'),
          'p_about': about.text.trim(),
        });
        final avatarSync = AvatarSyncService(widget.client!, widget.preferences);
        await avatarSync.onSignIn(widget.profile);
      }
      if (!mounted) return;
      await widget.preferences.setBool('openchat.onboarding.v1', true);
      widget.onDone();
    } on ArgumentError catch (e) {
      if (mounted) setState(() => error = e.message.toString());
    } catch (_) {
      if (mounted) setState(() => error = 'Could not save profile. Try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: ListView(
        padding: const EdgeInsets.all(32),
        children: [
          const Text(
            'Your profile.',
            style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text(
            'This is how you\'ll appear to contacts.',
            style: TextStyle(color: Color(0xFF66748A)),
          ),
          const SizedBox(height: 28),
          GestureDetector(
            onTap: _pickAvatar,
            child: CircleAvatar(
              radius: 60,
              backgroundColor: const Color(0xFFDDE5FF),
              backgroundImage: _pickedFile != null
                  ? html.ImageElement(src: html.URL.createObjectUrl(_pickedFile!)) as ImageProvider
                  : null,
              child: _pickedFile == null
                  ? Text(
                      widget.profile.name.isEmpty
                          ? '?'
                          : widget.profile.name[0].toUpperCase(),
                      style: const TextStyle(
                        fontSize: 48,
                        color: Color(0xFF245CDB),
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _pickAvatar,
            child: const Text('Add photo'),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: name,
            enabled: !busy,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Name',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: about,
            enabled: !busy,
            maxLength: 140,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'About',
              counterText: '',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 24),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          FilledButton(
            onPressed: busy ? null : _submit,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 56),
            ),
            child: Text(busy ? 'Saving…' : 'Continue'),
          ),
          const SizedBox(height: 16),
          const Text(
            'You can change this later in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
          ),
        ],
      ),
    );
  }
}