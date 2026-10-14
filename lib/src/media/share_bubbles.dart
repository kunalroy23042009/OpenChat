import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as device;
import 'package:url_launcher/url_launcher.dart';

import 'media_message.dart';

/// Shared contact card: avatar initial, name, numbers, save-to-device.
/// Tapping the card saves; it never opens anything sensitive.
class ContactBubble extends StatefulWidget {
  const ContactBubble({super.key, required this.body, required this.mine});
  final MediaBody body;
  final bool mine;
  @override
  State<ContactBubble> createState() => _ContactBubbleState();
}

class _ContactBubbleState extends State<ContactBubble> {
  bool _saving = false;
  String? _note;

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _note = null;
    });
    try {
      final status = await device.FlutterContacts.permissions
          .request(device.PermissionType.write);
      if (status != device.PermissionStatus.granted) {
        throw StateError('Contacts permission is required to save.');
      }
      final contact = device.Contact(
        name: device.Name(first: widget.body.contactName),
        phones: [
          for (final p in widget.body.contactPhones)
            device.Phone(number: p),
        ],
      );
      await device.FlutterContacts.create(contact);
      if (mounted) setState(() => _note = 'Saved to your contacts.');
    } catch (_) {
      if (mounted) setState(() => _note = 'Could not save this contact.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: widget.mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Card(
      child: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: CircleAvatar(
                child: Text(
                  widget.body.contactName.isEmpty
                      ? '?'
                      : widget.body.contactName[0].toUpperCase(),
                ),
              ),
              title: Text(
                widget.body.contactName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                widget.body.contactPhones.take(2).join('\n'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.person_add_alt_1),
              title: Text(_note ?? 'Save contact'),
              onTap: _saving ? null : _save,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Shared static location: coordinates, optional label, open-in-maps.
/// No map SDK involved — the button deep-links to the Maps app.
class LocationBubble extends StatelessWidget {
  const LocationBubble({super.key, required this.body, required this.mine});
  final MediaBody body;
  final bool mine;

  Future<void> _openMaps(BuildContext context) async {
    final lat = body.latitude;
    final lng = body.longitude;
    if (lat == null || lng == null) return;
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Maps.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Card(
      child: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 120,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(12),
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.location_on,
                      size: 40,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      body.text.isNotEmpty ? body.text : 'Shared location',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${body.latitude?.toStringAsFixed(5)}, ${body.longitude?.toStringAsFixed(5)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: const Icon(Icons.map_outlined),
              title: const Text('Open in Maps'),
              onTap: () => _openMaps(context),
            ),
          ],
        ),
      ),
    ),
  );
}
