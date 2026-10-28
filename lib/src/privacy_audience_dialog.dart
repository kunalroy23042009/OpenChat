import 'package:flutter/material.dart';

import 'contacts_repository.dart';

class AudienceDialog extends StatefulWidget {
  const AudienceDialog({
    super.key,
    required this.title,
    required this.contacts,
    required this.selected,
  });

  final String title;
  final List<CloudContact> contacts;
  final Set<String> selected;

  @override
  State<AudienceDialog> createState() => _AudienceDialogState();
}

class _AudienceDialogState extends State<AudienceDialog> {
  late final Set<String> _selected = {...widget.selected};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 420,
      child: widget.contacts.isEmpty
          ? const Text('You do not have any accepted contacts yet.')
          : ListView.builder(
              shrinkWrap: true,
              itemCount: widget.contacts.length,
              itemBuilder: (context, index) {
                final contact = widget.contacts[index];
                return CheckboxListTile(
                  value: _selected.contains(contact.userId),
                  title: Text(contact.name),
                  subtitle: contact.username.isEmpty
                      ? null
                      : Text('@${contact.username}'),
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        _selected.add(contact.userId);
                      } else {
                        _selected.remove(contact.userId);
                      }
                    });
                  },
                );
              },
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _selected),
        child: const Text('Save audience'),
      ),
    ],
  );
}
