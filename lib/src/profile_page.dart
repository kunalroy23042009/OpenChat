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

  bool get signedIn => widget.client?.auth.currentUser != null;

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
      } else {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 512,
          imageQuality: 85,
        );
        if (picked != null && mounted) {
          await widget.profile.setAvatar(picked.path);
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
      await syncCloud(silent: true);
      if (mounted) setState(() => feedback = 'Profile updated.');
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

  Future<void> syncCloud({bool silent = false}) async {
    final client = widget.client;
    if (client == null || client.auth.currentUser == null) {
      if (!silent && mounted) {
        setState(() => feedback = 'Sign in to sync your profile to the cloud.');
      }
      return;
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
        setState(() => feedback = 'Profile synced to your cloud account.');
      }
    } catch (e) {
      if (mounted) setState(() => feedback = cloudError(e));
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
                  'This is your username in chats, not your login email. People find you by @username.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
                ),
              ),
              const SizedBox(height: 16),
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
                  'Your photo never leaves this phone yet. Photo sharing arrives with media messaging.',
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
          style: const TextStyle(fontSize: 17, color: Color(0xFF22334E)),
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
