import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'contacts_repository.dart';
import 'local_profile.dart';

/// WhatsApp-style profile: photo, name, and about line.
/// The photo stays on this device; name/about sync to the cloud account.
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.profile, this.client});
  final LocalProfile profile;
  final SupabaseClient? client;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool busy = false;
  String? feedback;
  String? cloudUsername;
  String? cloudPhone;

  bool get signedIn => widget.client?.auth.currentUser != null;

  @override
  void initState() {
    super.initState();
    _loadCloud();
  }

  /// Pulls the authoritative cloud profile (username, self-asserted phone) so
  /// the page shows what contacts actually see, not just local edits.
  Future<void> _loadCloud() async {
    final client = widget.client;
    if (client == null || client.auth.currentUser == null) return;
    try {
      final cloud = await SupabaseContactsRepository(client).profile();
      if (!mounted) return;
      setState(() {
        cloudUsername = cloud.username;
        cloudPhone = cloud.phone;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback = 'Could not load account details. Check your connection and reopen Profile.',
        );
      }
    }
  }

  Future<void> editAccountField({required bool phone}) async {
    final client = widget.client;
    if (client == null || !signedIn || busy) return;
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _AccountFieldDialog(
        phone: phone,
        initial: phone ? cloudPhone ?? '' : cloudUsername ?? '',
      ),
    );
    if (value == null || !mounted) return;
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      final repository = SupabaseContactsRepository(client);
      if (phone) {
        await repository.setMyPhone(value);
      } else {
        // Updating a username must not overwrite a newer name/about with
        // stale device-local profile values.
        final current = await repository.profile();
        await repository.saveProfile(
          current.name,
          value,
          current.about ?? LocalProfile.defaultAbout,
        );
      }
      if (!mounted) return;
      setState(() {
        if (phone) {
          cloudPhone = value;
        } else {
          cloudUsername = value;
        }
        feedback = phone
            ? 'Phone number saved (not SMS-verified).'
            : 'Username updated.';
      });
    } catch (e) {
      if (mounted) setState(() => feedback = cloudError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> changePhoto() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            if (widget.profile.avatarPath != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove photo'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      if (choice == 'remove') {
        await widget.profile.removeAvatar();
        await _syncAvatarUrl(null);
      } else {
        final picked = await ImagePicker().pickImage(
          source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 512,
          imageQuality: 85,
        );
        if (picked != null && mounted) {
          await widget.profile.setAvatar(picked.path);
          await _syncAvatarUrl(widget.profile.avatarPath);
        }
      }
    } on PlatformException {
      if (mounted) {
        setState(() => feedback = 'Could not open your photo library.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => feedback = 'Could not update your photo. Try again.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Uploads the device photo to the public avatars bucket and points the
  /// cloud profile at it. Best-effort: the local photo stays regardless.
  Future<void> _syncAvatarUrl(String? localPath) async {
    final client = widget.client;
    if (client == null || client.auth.currentUser == null || !mounted) return;
    try {
      final repository = SupabaseContactsRepository(client);
      if (localPath == null) {
        await repository.setAvatarUrl(null);
        return;
      }
      final uid = client.auth.currentUser!.id;
      final name = '$uid/avatar_${DateTime.now().microsecondsSinceEpoch}.jpg';
      await client.storage.from('avatars').upload(
        name,
        File(localPath),
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
      );
      await repository.setAvatarUrl(client.storage.from('avatars').getPublicUrl(name));
    } catch (_) {
      if (mounted) {
        setState(() => feedback = 'Photo saved on this device. Cloud sync failed — check your connection.');
      }
    }
  }

  Future<void> editField({required bool isName}) async {
    final controller = TextEditingController(
      text: isName ? widget.profile.name : widget.profile.about,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isName ? 'Your name' : 'About'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: isName ? 60 : LocalProfile.maxAboutLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            counterText: '',
            hintText: isName ? null : LocalProfile.defaultAbout,
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      await widget.profile.save(
        name: isName ? value : widget.profile.name,
        about: isName ? widget.profile.about : value,
      );
      final synced = await syncCloud(silent: true);
      if (mounted && synced) {
        setState(
          () => feedback = signedIn
              ? 'Profile updated.'
              : 'Saved on this device.',
        );
      }
    } on ArgumentError catch (e) {
      if (mounted) setState(() => feedback = e.message.toString());
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback = signedIn
              ? 'Saved on this device, but cloud sync failed. Try syncing again.'
              : 'Saved on this device.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> syncCloud({bool silent = false}) async {
    final client = widget.client;
    if (client == null || client.auth.currentUser == null) {
      if (!silent && mounted) {
        setState(() => feedback = 'Sign in to sync your profile to the cloud.');
      }
      return true;
    }
    setState(() {
      busy = true;
      if (!silent) feedback = null;
    });
    try {
      final repository = SupabaseContactsRepository(client);
      final cloud = await repository.profile();
      final username =
          cloud.username ??
          'member${client.auth.currentUser!.id.replaceAll('-', '').substring(0, 6)}';
      await repository.saveProfile(
        widget.profile.name,
        username,
        widget.profile.about,
      );
      if (mounted) {
        setState(() {
          cloudUsername = username;
          feedback = 'Profile synced to your cloud account.';
        });
      }
      return true;
    } catch (e) {
      if (mounted) setState(() => feedback = cloudError(e));
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Profile')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListenableBuilder(
          listenable: widget.profile,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: Stack(
                  children: [
                    CircleAvatar(
                      radius: 64,
                      backgroundColor: const Color(0xFFDDE5FF),
                      backgroundImage: widget.profile.avatarFile != null
                          ? FileImage(widget.profile.avatarFile!)
                          : null,
                      child: widget.profile.avatarFile == null
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
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: GestureDetector(
                        onTap: busy ? null : changePhoto,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(
                            color: Color(0xFF245CDB),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.camera_alt,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              if (busy) const LinearProgressIndicator(),
              _ProfileRow(
                icon: Icons.person_outline,
                label: 'Name',
                value: widget.profile.name.isEmpty
                    ? 'Add your name'
                    : widget.profile.name,
                onEdit: busy ? null : () => editField(isName: true),
              ),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'This is your display name. People find your account by its unique @username.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
                ),
              ),
              const SizedBox(height: 16),
              if (signedIn) ...[
                _ProfileRow(
                  icon: Icons.alternate_email,
                  label: 'Username',
                  value: cloudUsername == null
                      ? 'Add a username'
                      : '@$cloudUsername',
                  onEdit: busy ? null : () => editAccountField(phone: false),
                ),
                const SizedBox(height: 16),
                _ProfileRow(
                  icon: Icons.phone_outlined,
                  label: 'Phone number',
                  value: cloudPhone?.isNotEmpty == true
                      ? cloudPhone!
                      : 'Optional — add a number',
                  onEdit: busy ? null : () => editAccountField(phone: true),
                ),
                const Padding(
                  padding: EdgeInsets.all(4),
                  child: Text(
                    'For contact discovery only. Not SMS-verified.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              _ProfileRow(
                icon: Icons.info_outline,
                label: 'About',
                value: widget.profile.about,
                onEdit: busy ? null : () => editField(isName: false),
              ),
              const SizedBox(height: 16),
              _ProfileRow(
                icon: Icons.alternate_email,
                label: 'Account',
                value: signedIn
                    ? widget.client!.auth.currentUser!.email ?? 'Signed in'
                    : 'Not signed in — profile stays on this device',
                onEdit: null,
              ),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Your profile photo is stored on this device and shared with your contacts when signed in.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
                ),
              ),
              const SizedBox(height: 16),
              if (signedIn)
                OutlinedButton.icon(
                  onPressed: busy ? null : () => syncCloud(),
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Sync name & about to cloud'),
                ),
              if (feedback != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Semantics(liveRegion: true, child: Text(feedback!)),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AccountFieldDialog extends StatefulWidget {
  const _AccountFieldDialog({required this.phone, required this.initial});
  final bool phone;
  final String initial;
  @override
  State<_AccountFieldDialog> createState() => _AccountFieldDialogState();
}

class _AccountFieldDialogState extends State<_AccountFieldDialog> {
  late final controller = TextEditingController(text: widget.initial);
  final form = GlobalKey<FormState>();
  void save() {
    if (form.currentState!.validate()) {
      Navigator.pop(
        context,
        widget.phone
            ? controller.text.trim()
            : controller.text.trim().toLowerCase(),
      );
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.phone ? 'Phone number' : 'Username'),
    content: Form(
      key: form,
      child: TextFormField(
        controller: controller,
        autofocus: true,
        keyboardType: widget.phone ? TextInputType.phone : TextInputType.text,
        autocorrect: false,
        decoration: InputDecoration(
          hintText: widget.phone ? '+14155552671' : 'your_username',
          helperText: widget.phone
              ? 'Leave blank to remove your number.'
              : '3–24 letters, numbers or underscores.',
        ),
        validator: (value) {
          final clean = (value ?? '').trim().toLowerCase();
          if (widget.phone) {
            return clean.isEmpty ||
                    RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(clean)
                ? null
                : 'Include + and your country code.';
          }
          return RegExp(r'^[a-z][a-z0-9_]{2,23}$').hasMatch(clean)
              ? null
              : 'Start with a letter; use 3–24 valid characters.';
        },
        onFieldSubmitted: (_) => save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: save, child: const Text('Save')),
    ],
  );
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.icon,
    required this.label,
    required this.value,
    this.onEdit,
  });
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(icon, color: const Color(0xFF66748A)),
      title: Text(
        label,
        style: const TextStyle(fontSize: 12, color: Color(0xFF66748A)),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          value,
          style: TextStyle(
            fontSize: 17,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
      trailing: onEdit == null
          ? null
          : IconButton(
              tooltip: 'Edit $label',
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
    ),
  );
}
