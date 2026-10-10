import 'package:supabase_flutter/supabase_flutter.dart';

class AccountProfile {
  const AccountProfile({required this.name, this.username, this.about});
  final String name;
  final String? username;
  final String? about;
}

class CloudContact {
  const CloudContact({
    required this.userId,
    this.requestId,
    required this.name,
    required this.username,
    this.about,
    required this.status,
    required this.incoming,
  });
  final String userId;
  final String? requestId;
  final String name;
  final String username;
  final String? about;
  final String status;
  final bool incoming;
  factory CloudContact.fromJson(Map<String, dynamic> json) => CloudContact(
    userId: json['user_id'] as String,
    requestId: json['request_id'] as String?,
    name: json['display_name'] as String,
    username: json['username'] as String? ?? '',
    about: json['about'] as String?,
    status: json['status'] as String,
    incoming: json['incoming'] as bool,
  );
}

abstract class ContactsRepository {
  Future<AccountProfile> profile();
  Future<void> saveProfile(String name, String username, String about);
  Future<List<CloudContact>> contacts();
  Future<String> invite(String username);
  Future<String> inviteByPhone(String phone);
  Future<void> respond(String requestId, bool accept);
  Future<void> cancelInvite(String requestId);
  Future<void> block(String userId);
  Future<void> unblock(String userId);
  Future<void> deleteAccount();
}

class SupabaseContactsRepository implements ContactsRepository {
  SupabaseContactsRepository(this.client);
  final SupabaseClient client;
  @override
  Future<AccountProfile> profile() async {
    final id = client.auth.currentUser?.id;
    if (id == null) throw const AuthException('Sign in to load your profile.');
    final row = await client
        .from('profiles')
        .select('display_name, username, about')
        .eq('id', id)
        .single();
    return AccountProfile(
      name: row['display_name'] as String,
      username: row['username'] as String?,
      about: row['about'] as String?,
    );
  }

  @override
  Future<void> saveProfile(String name, String username, String about) async {
    await client.rpc(
      'save_profile',
      params: {
        'p_display_name': name.trim(),
        'p_username': username.trim().toLowerCase(),
        'p_about': about.trim(),
      },
    );
  }

  @override
  Future<List<CloudContact>> contacts() async {
    final rows = await client.rpc('list_my_contacts') as List;
    return rows
        .map(
          (row) => CloudContact.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
  }

  @override
  Future<String> invite(String username) async => await client.rpc(
    'send_contact_invite',
    params: {'p_username': username.trim().toLowerCase()},
  ) as String;

  @override
  Future<String> inviteByPhone(String phone) async => await client.rpc(
    'send_invite_by_phone',
    params: {'p_phone': phone.trim()},
  ) as String;

  @override
  Future<void> respond(String requestId, bool accept) async {
    await client.rpc(
      'respond_contact_invite',
      params: {'p_request_id': requestId, 'p_accept': accept},
    );
  }

  @override
  Future<void> cancelInvite(String requestId) async {
    await client.rpc(
      'cancel_contact_invite',
      params: {'p_request_id': requestId},
    );
  }

  @override
  Future<void> block(String userId) async {
    await client.rpc('block_contact', params: {'p_user_id': userId});
  }

  @override
  Future<void> unblock(String userId) async {
    await client.rpc('unblock_contact', params: {'p_user_id': userId});
  }

  @override
  Future<void> deleteAccount() async {
    await client.rpc('delete_account');
    await client.auth.signOut();
  }
}

String cloudError(Object error) {
  if (error is AuthException) return error.message;
  if (error is PostgrestException) {
    if (error.code == '23505') {
      return 'That username is taken. Choose another one.';
    }
    if ([
      '42P01',
      '42703',
      '42883',
      'PGRST202',
      'PGRST205',
    ].contains(error.code)) {
      return 'The backend needs its database migrations. Run all three SQL files in supabase/migrations, then retry.';
    }
    if (error.code == 'P0001') return error.message;
    if (error.code == '42501' || error.code == 'PGRST301') {
      return 'Access denied. Sign in again and retry.';
    }
  }
  return 'Could not complete the request. Check your connection and retry.';
}
