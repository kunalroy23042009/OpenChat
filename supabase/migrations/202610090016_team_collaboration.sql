-- Team collaboration: tasks, polls, resource vault, communities and channels.
-- Apply after 202610090015_conversation_rpcs.sql.
begin;

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  message_id uuid references public.group_messages(id) on delete set null,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  creator_id uuid not null references public.profiles(id) on delete cascade,
  assignee_id uuid references public.profiles(id) on delete set null,
  title varchar(150) not null check (char_length(trim(title)) between 1 and 150),
  description text,
  status varchar(20) not null default 'todo'
    check (status in ('todo','in_progress','review','completed')),
  priority varchar(10) not null default 'medium'
    check (priority in ('low','medium','high','urgent')),
  due_date timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index tasks_conversation_status on public.tasks(conversation_id, status);
alter table public.tasks enable row level security;
grant select on public.tasks to authenticated;
create policy tasks_member_read on public.tasks for select to authenticated using (
  exists (select 1 from public.conversation_members cm
          where cm.conversation_id = tasks.conversation_id and cm.user_id = (select auth.uid()))
);

create table public.poll_votes (
  message_id uuid not null references public.group_messages(id) on delete cascade,
  option_index smallint not null check (option_index between 0 and 11),
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (message_id, option_index, user_id)
);
alter table public.poll_votes enable row level security;
grant select on public.poll_votes to authenticated;
create policy poll_votes_member_read on public.poll_votes for select to authenticated using (
  exists (select 1 from public.group_messages gm join public.conversation_members cm
    on cm.conversation_id = gm.conversation_id
    where gm.id = poll_votes.message_id and cm.user_id = (select auth.uid()))
);

create table public.communities (
  id uuid primary key default gen_random_uuid(),
  name varchar(100) not null,
  description text,
  avatar_url text,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  announcement_conversation_id uuid references public.conversations(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.community_conversations (
  community_id uuid not null references public.communities(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (community_id, conversation_id)
);
alter table public.communities enable row level security;
alter table public.community_conversations enable row level security;
grant select on public.communities, public.community_conversations to authenticated;
create policy communities_member_read on public.communities for select to authenticated using (
  owner_id = (select auth.uid()) or exists (
    select 1 from public.community_conversations cc join public.conversation_members cm
      on cm.conversation_id = cc.conversation_id
    where cc.community_id = communities.id and cm.user_id = (select auth.uid()))
);
create policy community_links_member_read on public.community_conversations for select to authenticated using (
  exists (select 1 from public.communities c where c.id = community_id and
    (c.owner_id = (select auth.uid()) or exists (select 1 from public.conversation_members cm
      where cm.conversation_id = community_conversations.conversation_id and cm.user_id = (select auth.uid()))))
);

create or replace function public.create_task(
  p_conversation_id uuid, p_title text, p_description text default null,
  p_assignee_id uuid default null, p_due_date timestamptz default null,
  p_priority varchar default 'medium', p_message_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); task_id uuid;
begin
  if me is null or not exists (select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = me) then raise exception 'Not a member'; end if;
  if p_priority not in ('low','medium','high','urgent') then raise exception 'Invalid priority'; end if;
  if p_assignee_id is not null and not exists (select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = p_assignee_id) then raise exception 'Assignee is not a member'; end if;
  insert into public.tasks(message_id, conversation_id, creator_id, assignee_id, title,
    description, due_date, priority)
  values(p_message_id, p_conversation_id, me, p_assignee_id, trim(p_title),
    p_description, p_due_date, p_priority) returning id into task_id;
  insert into public.group_messages(conversation_id, sender_id, content, type, metadata)
  values(p_conversation_id, me, 'Created task: ' || trim(p_title), 'task',
    jsonb_build_object('task_id', task_id, 'priority', p_priority, 'due_date', p_due_date));
  return task_id;
end $$;

create or replace function public.update_task_status(p_task_id uuid, p_status varchar)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); t public.tasks;
begin
  if p_status not in ('todo','in_progress','review','completed') then raise exception 'Invalid status'; end if;
  select * into t from public.tasks where id = p_task_id;
  if t.id is null or not exists (select 1 from public.conversation_members
    where conversation_id = t.conversation_id and user_id = me) then raise exception 'Task unavailable'; end if;
  update public.tasks set status = p_status, updated_at = now() where id = p_task_id;
  insert into public.group_messages(conversation_id, sender_id, content, type, metadata)
  values(t.conversation_id, me, 'Task "' || t.title || '" moved to ' || replace(p_status, '_', ' '),
    'system', jsonb_build_object('task_id', t.id, 'status', p_status));
end $$;

create or replace function public.create_poll(p_conversation_id uuid, p_question text,
  p_options jsonb, p_multiple boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); message_id uuid; option_count integer;
begin
  if me is null or not exists (select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = me) then raise exception 'Not a member'; end if;
  option_count := jsonb_array_length(p_options);
  if char_length(trim(p_question)) not between 1 and 300 or option_count not between 2 and 12
    then raise exception 'Poll requires a question and 2-12 options'; end if;
  insert into public.group_messages(conversation_id, sender_id, content, type, metadata)
  values(p_conversation_id, me, trim(p_question), 'poll',
    jsonb_build_object('options', p_options, 'multiple', p_multiple)) returning id into message_id;
  return message_id;
end $$;

create or replace function public.vote_poll(p_message_id uuid, p_option_index smallint)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); poll public.group_messages; multiple boolean;
begin
  select * into poll from public.group_messages where id = p_message_id and type = 'poll';
  if poll.id is null or not exists (select 1 from public.conversation_members where
    conversation_id = poll.conversation_id and user_id = me) then raise exception 'Poll unavailable'; end if;
  if p_option_index < 0 or p_option_index >= jsonb_array_length(poll.metadata->'options') then raise exception 'Invalid option'; end if;
  multiple := coalesce((poll.metadata->>'multiple')::boolean, false);
  if not multiple then delete from public.poll_votes where message_id = p_message_id and user_id = me; end if;
  insert into public.poll_votes(message_id, option_index, user_id) values(p_message_id, p_option_index, me)
    on conflict do nothing;
end $$;

revoke all on function public.create_task(uuid,text,text,uuid,timestamptz,varchar,uuid),
  public.update_task_status(uuid,varchar), public.create_poll(uuid,text,jsonb,boolean),
  public.vote_poll(uuid,smallint) from public, anon, authenticated;
grant execute on function public.create_task(uuid,text,text,uuid,timestamptz,varchar,uuid),
  public.update_task_status(uuid,varchar), public.create_poll(uuid,text,jsonb,boolean),
  public.vote_poll(uuid,smallint) to authenticated;

commit;
