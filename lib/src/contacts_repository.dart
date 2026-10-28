import 'package:supabase_flutter/supabase_flutter.dart';

class AccountProfile {
  const AccountProfile({
    required this.name,
    this.username,
    this.about,
    this.phone,
    this.avatarUrl,
    this.avatarPath,
  });
  final String name;
  final String? username;
  final String? about;
  final String? avatarUrl;
  final String? avatarPath;

  /// Self-asserted number until SMS verification is enabled.
  final String? phone;
}

class CloudContact {
  const CloudContact({
    required this.userId,
    this.requestId,
    required this.name,
    required this.username,
    this.about,
    this.avatarUrl,
    this.avatarPath,
    required this.status,
    required this.incoming,
  });
  final String userId;
  final String? requestId;
  final String name;
  final String username;
  final String? about;
  final String? avatarUrl;
  final String? avatarPath;
  final String status;
  final bool incoming;
  factory CloudContact.fromJson(Map<String, dynamic> json) => CloudContact(
    userId: json['user_id'] as String,
    requestId: json['request_id'] as String?,
    name: json['display_name'] as String,
    username: json['username'] as String? ?? '',
    about: json['about'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    avatarPath: json['avatar_path'] as String?,
    status: json['status'] as String,
    incoming: json['incoming'] as bool,
  );
}

abstract class ContactsRepository {
  Future<AccountProfile> profile();
  Future<void> saveProfile(String name, String username, String about);
  Future<void> setAvatarUrl(String? url);
  Future<void> setMyPhone(String phone);
  Future<CloudContact?> findByPhone(String phone);
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
        .select(
          'display_name, username, about, phone_number, avatar_url, avatar_path',
        )
        .eq('id', id)
        .single();
    return AccountProfile(
      name: row['display_name'] as String,
      username: row['username'] as String?,
      about: row['about'] as String?,
      phone: row['phone_number'] as String?,
      avatarPath: row['avatar_path'] as String?,
      avatarUrl: await _avatarUrl(
        row['avatar_path'] as String?,
        row['avatar_url'] as String?,
      ),
    );
  }

  @override
  Future<void> setAvatarUrl(String? url) async {
    await client.rpc('set_avatar_url', params: {'p_url': url});
  }

  Future<String?> _avatarUrl(String? path, String? legacyUrl) async {
    if (path == null || path.isEmpty) return legacyUrl;
    try {
      return await client.storage
          .from('profile-avatars')
          .createSignedUrl(path, 60 * 60);
    } catch (_) {
      return null;
    }
  }

  Future<CloudContact> _contactFromRow(Map<String, dynamic> row) async {
    final parsed = CloudContact.fromJson(row);
    return CloudContact(
      userId: parsed.userId,
      requestId: parsed.requestId,
      name: parsed.name,
      username: parsed.username,
      about: parsed.about,
      avatarPath: parsed.avatarPath,
      avatarUrl: await _avatarUrl(parsed.avatarPath, parsed.avatarUrl),
      status: parsed.status,
      incoming: parsed.incoming,
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
    return Future.wait(
      rows.map((row) => _contactFromRow(Map<String, dynamic>.from(row as Map))),
    );
  }

  @override
  Future<void> setMyPhone(String phone) async {
    await client.rpc('set_my_phone', params: {'p_phone': phone.trim()});
  }

  @override
  Future<CloudContact?> findByPhone(String phone) async {
    final row = await client.rpc(
      'find_contact_by_phone',
      params: {'p_phone': phone.trim()},
    ) as Map<String, dynamic>?;
    if (row == null) return null;
    return _contactFromRow({...row, 'status': 'found', 'incoming': false});
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
