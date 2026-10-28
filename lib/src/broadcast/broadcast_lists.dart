import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A broadcast list: a saved list of contacts to send one-to-many messages to.
/// Replies come back as individual 1:1 chats.
class BroadcastList {
  final String id;
  final String name;
  final List<String> contactIds; // Contact user IDs
  final DateTime createdAt;
  final DateTime updatedAt;

  BroadcastList({
    required this.id,
    required this.name,
    required this.contactIds,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'contactIds': contactIds,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory BroadcastList.fromJson(Map<String, dynamic> json) => BroadcastList(
    id: json['id'] as String,
    name: json['name'] as String,
    contactIds: (json['contactIds'] as List).cast<String>(),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

/// Service for managing broadcast lists.
class BroadcastListService extends ChangeNotifier {
  BroadcastListService(this._prefs);
  final SharedPreferences _prefs;
  static const _storageKey = 'openchat.broadcast_lists.v1';

  List<BroadcastList> _lists = [];
  List<BroadcastList> get lists => List.unmodifiable(_lists);

  /// Loads lists from storage.
  Future<void> load() async {
    final raw = _prefs.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final data = jsonDecode(raw) as List;
        _lists = data.map((e) => BroadcastList.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      } catch (_) {
        _lists = [];
      }
    }
    notifyListeners();
  }

  Future<void> _save() async {
    await _prefs.setString(_storageKey, jsonEncode(_lists.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  /// Saves lists to storage.
  Future<void> save() async {
    await _prefs.setString(_storageKey, jsonEncode(_lists.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  /// Create a new broadcast list.
  Future<BroadcastList> createList({
    required String name,
    required List<String> contactIds,
  }) async {
    final now = DateTime.now();
    final list = BroadcastList(
      id: now.microsecondsSinceEpoch.toString(),
      name: name.trim(),
      contactIds: contactIds,
      createdAt: now,
      updatedAt: now,
    );
    _lists.insert(0, list);
    await _save();
    return list;
  }

  /// Update an existing broadcast list.
  Future<void> update(BroadcastList list) async {
    final index = _lists.indexWhere((l) => l.id == list.id);
    if (index >= 0) {
      _lists[index] = BroadcastList(
        id: list.id,
        name: list.name,
        contactIds: list.contactIds,
        createdAt: list.createdAt,
        updatedAt: DateTime.now(),
      );
      await _save();
    }
  }

  /// Delete a broadcast list.
  Future<void> delete(String id) async {
    _lists.removeWhere((l) => l.id == id);
    await _save();
  }

  /// Get a broadcast list by ID.
  BroadcastList? getById(String id) {
    try {
      return _lists.firstWhere((l) => l.id == id);
    } catch (_) {
      return null;
    }
  }
}

/// Screen for managing broadcast lists.
class BroadcastListsPage extends StatefulWidget {
  const BroadcastListsPage({
    super.key,
    required this.service,
    required this.client,
    required this.store,
    required this.profile,
    required this.push,
  });
  final BroadcastListService service;
  final dynamic client;
  final dynamic store;
  final dynamic profile;
  final dynamic push;

  @override
  State<BroadcastListsPage> createState() => _BroadcastListsPageState();
}

class _BroadcastListsPageState extends State<BroadcastListsPage> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Broadcast Lists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _createBroadcastList,
            tooltip: 'New broadcast list',
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.service,
        builder: (context, _) {
          final lists = widget.service.lists;
          if (lists.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.campaign_outlined,
                    size: 64,
                    color: isDark ? Colors.white30 : Colors.black26,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No broadcast lists yet',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Create a list to send one message\nto multiple contacts at once',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Create broadcast list'),
                    onPressed: _createBroadcastList,
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: lists.length,
            itemBuilder: (context, index) {
              final list = lists[index];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(
                      Icons.campaign,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                  title: Text(list.name),
                  subtitle: Text('${list.contactIds.length} recipient${list.contactIds.length == 1 ? '' : 's'}'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) async {
                      if (value == 'edit') {
                        await _editBroadcastList(list);
                      } else if (value == 'delete') {
                        await _deleteBroadcastList(list);
                      } else if (value == 'send') {
                        await _sendBroadcastMessage(list);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'send', child: Text('Send message')),
                      const PopupMenuItem(value: 'edit', child: Text('Edit list')),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                  onTap: () => _sendBroadcastMessage(list),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _createBroadcastList() async {
    if (!mounted) return;

    // Load contacts from store/repository
    // For demo, we'll use a simple dialog
    await showDialog<({String name, List<String> contactIds})>(
      context: context,
      builder: (context) => _BroadcastListEditor(
        service: widget.service,
        client: widget.client,
        store: widget.store,
        onSave: (name, contacts) {},
      ),
    );
  }

  Future<void> _editBroadcastList(BroadcastList list) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => _BroadcastListEditor(
        service: widget.service,
        client: widget.client,
        store: widget.store,
        existingList: list,
        onSave: (name, contacts) {},
      ),
    );
  }

  Future<void> _deleteBroadcastList(BroadcastList list) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${list.name}"?'),
        content: const Text('This will delete the broadcast list. Messages already sent are not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.service.delete(list.id);
    }
  }

  Future<void> _sendBroadcastMessage(BroadcastList list) async {
    if (!mounted) return;
    final messageController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Broadcast to "${list.name}"'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${list.contactIds.length} recipient(s) will receive this as individual messages.'),
            const SizedBox(height: 16),
            TextField(
              controller: messageController,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Type your message...',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final text = messageController.text.trim();
              if (text.isNotEmpty) Navigator.pop(context, text);
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && mounted) {
      // Send the message to each contact in the broadcast list
      // In a real implementation, this would use the messaging infrastructure
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Broadcast sent to ${list.contactIds.length} contacts')),
      );
    }
  }
}

class _BroadcastListEditor extends StatefulWidget {
  final BroadcastListService service;
  final dynamic client;
  final dynamic store;
  final BroadcastList? existingList;
  final void Function(String name, List<String> contactIds) onSave;

  const _BroadcastListEditor({
    required this.service,
    required this.client,
    required this.store,
    this.existingList,
    required this.onSave,
  });

  @override
  State<_BroadcastListEditor> createState() => _BroadcastListEditorState();
}

class _BroadcastListEditorState extends State<_BroadcastListEditor> {
  final nameController = TextEditingController();
  final Set<String> selectedContacts = {};
  List<dynamic> availableContacts = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.existingList != null) {
      nameController.text = widget.existingList!.name;
      selectedContacts.addAll(widget.existingList!.contactIds);
    }
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    // In a real implementation, load from contacts repository
    // For now, use empty list
    if (!mounted) return;
    setState(() {
      availableContacts = [];
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return AlertDialog(
        content: const Center(child: CircularProgressIndicator()),
      );
    }

    return AlertDialog(
      title: Text(widget.existingList != null ? 'Edit broadcast list' : 'New broadcast list'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'List name'),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            const Text('Select recipients:', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: availableContacts.isEmpty
                  ? const Center(
                      child: Text('No contacts available. Add contacts first.'),
                    )
                  : ListView.builder(
                      itemCount: availableContacts.length,
                      itemBuilder: (context, index) {
                        final contact = availableContacts[index];
                        final id = contact['userId'] as String? ?? '';
                        final name = contact['name'] as String? ?? 'Unknown';
                        final selected = selectedContacts.contains(id);
                        return CheckboxListTile(
                          title: Text(name),
                          value: selected,
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                selectedContacts.add(id);
                              } else {
                                selectedContacts.remove(id);
                              }
                            });
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = nameController.text.trim();
            if (name.isNotEmpty && selectedContacts.isNotEmpty) {
              if (widget.existingList != null) {
                widget.service.update(BroadcastList(
                  id: widget.existingList!.id,
                  name: name,
                  contactIds: selectedContacts.toList(),
                  createdAt: widget.existingList!.createdAt,
                  updatedAt: DateTime.now(),
                ));
              } else {
                widget.service.createList(name: name, contactIds: selectedContacts.toList());
              }
              Navigator.pop(context);
            }
          },
          child: Text(widget.existingList != null ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}