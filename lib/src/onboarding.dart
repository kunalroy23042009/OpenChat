import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'contacts_repository.dart';
import 'auth/password_auth.dart';
import 'auth/password_field.dart';
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
            Container(
              padding: const EdgeInsets.all(28),
              decoration: const BoxDecoration(
                color: Color(0xFFE4EBFF),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.forum_rounded,
                size: 64,
                color: Color(0xFF245CDB),
              ),
            ),
            const SizedBox(height: 36),
            const Text(
              'Welcome to\nopen chat',
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
              'Your keys stay on your phone.',
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
              'A local demo for now. Real end-to-end encrypted messaging arrives in the next milestone.',
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
    // Google sign-in completes in the browser; advance when its session lands.
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
                'Use your Open Chat password here. Google passwords work only on Google’s sign-in page.',
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
            TextButton(
              onPressed: busy ? null : widget.onSkip,
              child: const Text('Skip for now'),
            ),
          ],
          if (feedback != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(liveRegion: true, child: Text(feedback!)),
            ),
        ],
      ),
    ),
  );
}

class _ProfileStep extends StatefulWidget {
  const _ProfileStep({
    required this.profile,
    this.client,
    required this.onDone,
  });
  final LocalProfile profile;
  final SupabaseClient? client;
  final VoidCallback onDone;

  @override
  State<_ProfileStep> createState() => _ProfileStepState();
}

class _ProfileStepState extends State<_ProfileStep> {
  final name = TextEditingController();
  final about = TextEditingController();
  bool busy = false;
  bool loadingCloud = false;
  String? cloudUsername;
  String? error;

  @override
  void initState() {
    super.initState();
    name.text = widget.profile.name;
    about.text = widget.profile.about;
    final client = widget.client;
    if (client != null && client.auth.currentUser != null) {
      loadingCloud = true;
      SupabaseContactsRepository(client)
          .profile()
          .then((cloud) {
            if (!mounted) return;
            setState(() {
              if (name.text.isEmpty) name.text = cloud.name;
              if (cloud.about != null && cloud.about!.isNotEmpty) {
                about.text = cloud.about!;
              }
              cloudUsername = cloud.username;
              loadingCloud = false;
            });
          })
          .catchError((Object _) {
            if (mounted) setState(() => loadingCloud = false);
          });
    }
  }

  @override
  void dispose() {
    name.dispose();
    about.dispose();
    super.dispose();
  }

  Future<void> pickPhoto() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        imageQuality: 85,
      );
      if (picked != null && mounted) {
        await widget.profile.setAvatar(picked.path);
      }
    } on PlatformException {
      if (mounted) {
        setState(() => error = 'Could not open your photo library. Try again.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not save that photo. Try another one.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty) {
      setState(() => error = 'Enter your name to continue.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.profile.save(name: name.text, about: about.text);
      final client = widget.client;
      if (client != null && client.auth.currentUser != null) {
        final username =
            cloudUsername ??
            'member${client.auth.currentUser!.id.replaceAll('-', '').substring(0, 6)}';
        await SupabaseContactsRepository(client)
            .saveProfile(widget.profile.name, username, widget.profile.about);
      }
      widget.onDone();
    } on ArgumentError catch (e) {
      if (mounted) {
        setState(() => error = e.message as String? ?? 'Check your entries.');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not save your profile. Check your connection and try again.',
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
            'Say hello.',
            style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text(
            'This is how contacts will see you.',
            style: TextStyle(color: Color(0xFF66748A)),
          ),
          const SizedBox(height: 28),
          Center(
            child: ListenableBuilder(
              listenable: widget.profile,
              builder: (context, _) {
                final file = widget.profile.avatarFile;
                return GestureDetector(
                  onTap: busy ? null : pickPhoto,
                  child: CircleAvatar(
                    radius: 56,
                    backgroundColor: const Color(0xFFDDE5FF),
                    backgroundImage: file != null ? FileImage(file) : null,
                    child: file == null
                        ? const Icon(
                            Icons.add_a_photo_outlined,
                            size: 36,
                            color: Color(0xFF245CDB),
                          )
                        : null,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Add a photo (optional, stays on this device)',
              style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
            ),
          ),
          const SizedBox(height: 24),
          if (loadingCloud) const LinearProgressIndicator(),
          TextField(
            controller: name,
            maxLength: 60,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Your name',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: about,
            maxLength: LocalProfile.maxAboutLength,
            decoration: const InputDecoration(
              labelText: 'About',
              hintText: LocalProfile.defaultAbout,
              counterText: '',
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(liveRegion: true, child: Text(error!)),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : save,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 52),
            ),
            child: Text(busy ? 'Please wait…' : 'Start chatting'),
          ),
        ],
      ),
    ),
  );
}
