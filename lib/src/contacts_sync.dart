import 'dart:math';

import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'contacts_repository.dart';

/// A device address-book number matched to an OpenChat account.
class SyncedContact {
  const SyncedContact({required this.contact, required this.phone});
  final CloudContact contact;
  final String phone;
}

/// An address-book entry with no OpenChat account yet (invitable via SMS).
class InvitableContact {
  const InvitableContact({required this.name, required this.phone});
  final String name;
  final String phone;

  Map<String, dynamic> toJson() => {'name': name, 'phone': phone};

  factory InvitableContact.fromJson(Map<String, dynamic> json) =>
      InvitableContact(
        name: json['name'] as String? ?? 'Contact',
        phone: json['phone'] as String? ?? '',
      );
}

/// WhatsApp-style address-book sync: read device numbers, normalize to
/// E.164, and batch-lookup who is already on OpenChat.
class ContactSyncService {
  ContactSyncService(this.client);
  final SupabaseClient client;

  /// Normalizes a raw address-book number to E.164, or null when unusable.
  /// Numbers without an explicit country code are dropped (never guessed).
  static String? normalizePhone(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^\d+]'), '');
    if (!cleaned.startsWith('+')) return null;
    final digits = cleaned.substring(1);
    if (!RegExp(r'^[1-9][0-9]{7,14}$').hasMatch(digits)) return null;
    return '+$digits';
  }

  /// Full sync: matched OpenChat users plus invitable address-book names.
  /// Unmatched entries are capped so a huge address book stays usable.
  Future<
    ({
      List<SyncedContact> matched,
      List<InvitableContact> invitable,
      int checked,
    })
  >
  syncFull({int invitableCap = 200}) async {
    final status = await FlutterContacts.permissions.request(
      PermissionType.read,
    );
    if (status != PermissionStatus.granted) {
      throw StateError('Contacts permission is required to find friends.');
    }
    final contacts = await FlutterContacts.getAll(
      properties: {ContactProperty.phone},
    );
    final numbers = <String, String>{};
    for (final c in contacts) {
      final shown = c.displayName?.trim() ?? '';
      final label = shown.isEmpty ? 'Contact' : shown;
      for (final p in c.phones) {
        final normalized = normalizePhone(p.number);
        if (normalized != null) numbers.putIfAbsent(normalized, () => label);
      }
    }
    if (numbers.isEmpty) {
      return (
        matched: const <SyncedContact>[],
        invitable: const <InvitableContact>[],
        checked: 0,
      );
    }
    final matched = await _lookupMatches(numbers.keys.toList());
    final onApp = {for (final m in matched) m.phone};
    final invitable = <InvitableContact>[];
    for (final entry in numbers.entries) {
      if (onApp.contains(entry.key)) continue;
      if (invitable.length >= invitableCap) break;
      invitable.add(InvitableContact(name: entry.value, phone: entry.key));
    }
    return (matched: matched, invitable: invitable, checked: numbers.length);
  }

  Future<({List<SyncedContact> matched, int checked})> sync() async {
    final result = await syncFull();
    return (matched: result.matched, checked: result.checked);
  }

  Future<List<SyncedContact>> _lookupMatches(List<String> all) async {
    final matched = <SyncedContact>[];
    for (var i = 0; i < all.length; i += 200) {
      final rows = await client.rpc(
        'lookup_contacts_by_phones',
        params: {'p_phones': all.sublist(i, min(i + 200, all.length))},
      ) as List;
      for (final row in rows) {
        final map = Map<String, dynamic>.from(row as Map);
        matched.add(
          SyncedContact(
            contact: CloudContact(
              userId: map['user_id'] as String,
              name: map['display_name'] as String? ?? 'OpenChat user',
              username: map['username'] as String? ?? '',
              about: map['about'] as String?,
              avatarUrl: map['avatar_url'] as String?,
              status: 'found',
              incoming: false,
            ),
            phone: map['phone'] as String? ?? '',
          ),
        );
      }
    }
    return matched;
  }
}
