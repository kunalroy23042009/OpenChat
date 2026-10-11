-- Conversations, members, and presence. Apply after 202610090013_ai_quota.sql.
-- Adds group and channel conversation support alongside existing 1-on-1
-- encrypted envelopes. Groups use server-visible messages (not E2EE) to
-- enable features like search, AI summarization, and task extraction.
begin;

-- ============================================================
-- 1. Enhanced profile columns for presence & status
-- ============================================================
alter table public.profiles
  add column if not exists avatar_url text,
  add column if not exists custom_status varchar(50) default 'Available',
  add column if not exists is_online boolean default false,
  add column if not exists last_seen timestamptz;

-- RLS: users can update their own presence columns.
grant update(avatar_url, custom_status, is_online, last_seen) on public.profiles to authenticated;

-- ============================================================
-- 2. Conversations table (direct, group, channel)
-- ============================================================
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  type varchar(10) not null check (type in ('direct', 'group', 'channel')),
  title varchar(100),
  description text,
  avatar_url text,
  invite_code varchar(32) unique,
  require_approval boolean default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index conversations_created_by on public.conversations(created_by);
alter table public.conversations enable row level security;
revoke all on public.conversations from anon, authenticated;
grant select on public.conversations to authenticated;

-- ============================================================
-- 3. Conversation members join table with roles
-- ============================================================
create table public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role varchar(10) not null check (role in ('member', 'admin', 'owner')) default 'member',
  joined_at timestamptz not null default now(),
  is_muted boolean default false,
  is_pinned boolean default false,
  is_archived boolean default false,
  unread_count integer default 0,
  primary key (conversation_id, user_id)
);
create index conv_members_user on public.conversation_members(user_id);
alter table public.conversation_members enable row level security;
revoke all on public.conversation_members from anon, authenticated;
grant select on public.conversation_members to authenticated;

-- Users can read their own memberships.
create policy conv_members_read on public.conversation_members for select to authenticated
  using (user_id = (select auth.uid()));

-- This policy must be created after conversation_members exists.
create policy conversations_read on public.conversations for select to authenticated
  using (
    exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = id
        and cm.user_id = (select auth.uid())
    )
  );

-- ============================================================
-- 4. Group messages table (server-readable for team features)
-- ============================================================
create table public.group_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  parent_message_id uuid references public.group_messages(id) on delete set null,
  content text not null check (char_length(content) between 1 and 8000),
  type varchar(20) not null default 'text'
    check (type in ('text','image','video','audio','document','location',
                     'vcard','poll','code_snippet','task','system')),
  media_url text,
  metadata jsonb default '{}'::jsonb,
  is_edited boolean default false,
  edited_at timestamptz,
  is_deleted boolean default false,
  is_view_once boolean default false,
  is_forwarded boolean default false,
  forward_count integer default 0,
  disappearing_at timestamptz,
  created_at timestamptz not null default now()
);
create index group_messages_conv on public.group_messages(conversation_id, created_at);
create index group_messages_sender on public.group_messages(sender_id);
create index group_messages_parent on public.group_messages(parent_message_id)
  where parent_message_id is not null;
alter table public.group_messages enable row level security;
revoke all on public.group_messages from anon, authenticated;
grant select on public.group_messages to authenticated;

-- Users can read messages in conversations they belong to.
create policy group_messages_read on public.group_messages for select to authenticated
  using (
    exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = conversation_id
        and cm.user_id = (select auth.uid())
    )
  );

-- ============================================================
-- 5. Message reactions
-- ============================================================
create table public.message_reactions (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.group_messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji varchar(8) not null,
  created_at timestamptz not null default now(),
  unique (message_id, user_id, emoji)
);
create index reactions_message on public.message_reactions(message_id);
alter table public.message_reactions enable row level security;
revoke all on public.message_reactions from anon, authenticated;
grant select on public.message_reactions to authenticated;

create policy reactions_read on public.message_reactions for select to authenticated
  using (
    exists (
      select 1 from public.group_messages gm
      join public.conversation_members cm on cm.conversation_id = gm.conversation_id
      where gm.id = message_id and cm.user_id = (select auth.uid())
    )
  );

-- ============================================================
-- 6. Starred messages
-- ============================================================
create table public.starred_messages (
  user_id uuid not null references public.profiles(id) on delete cascade,
  message_id uuid not null references public.group_messages(id) on delete cascade,
  starred_at timestamptz not null default now(),
  primary key (user_id, message_id)
);
alter table public.starred_messages enable row level security;
revoke all on public.starred_messages from anon, authenticated;
grant select, insert, delete on public.starred_messages to authenticated;

create policy starred_self on public.starred_messages for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- ============================================================
-- 7. Pinned messages (max 3 per conversation, enforced in RPC)
-- ============================================================
create table public.pinned_messages (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  message_id uuid not null references public.group_messages(id) on delete cascade,
  pinned_by uuid not null references public.profiles(id) on delete cascade,
  pinned_at timestamptz not null default now(),
  primary key (conversation_id, message_id)
);
alter table public.pinned_messages enable row level security;
revoke all on public.pinned_messages from anon, authenticated;
grant select on public.pinned_messages to authenticated;

create policy pinned_read on public.pinned_messages for select to authenticated
  using (
    exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = conversation_id
        and cm.user_id = (select auth.uid())
    )
  );

-- ============================================================
-- 8. Group message delivery receipts
-- ============================================================
create table public.group_message_receipts (
  message_id uuid not null references public.group_messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status varchar(10) not null check (status in ('sent', 'delivered', 'read')) default 'sent',
  updated_at timestamptz not null default now(),
  primary key (message_id, user_id)
);
alter table public.group_message_receipts enable row level security;
revoke all on public.group_message_receipts from anon, authenticated;
grant select on public.group_message_receipts to authenticated;

create policy receipts_read on public.group_message_receipts for select to authenticated
  using (
    exists (
      select 1 from public.group_messages gm
      join public.conversation_members cm on cm.conversation_id = gm.conversation_id
      where gm.id = message_id and cm.user_id = (select auth.uid())
    )
  );

commit;
