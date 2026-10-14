-- Chat-media quota for the direct Storage transport (images, videos,
-- chunked documents). The attachment_blobs RPCs (0007) govern the future
-- R2 transport and are NOT used by the current client; this trigger governs
-- the chat-media bucket the client actually writes to.
--
-- Caps (pilot, free-tier friendly):
--   single object: 64 MiB + 64 KiB headroom (covers sealed 64 MB videos,
--     10 MB images, 4 MiB document chunks, manifests).
--   per-user live total: 300 MiB across all owned objects in chat-media.
-- A 200 MB document (50x 4 MiB chunks) fits; a second large document does
-- not until the user deletes media. Failed/cancelled chunk uploads are
-- removed by the client; crash orphans (prefix without manifest.enc) are
-- reaped best-effort by DocumentTransfer.cleanupOrphans.
-- Idempotent: no explicit begin/commit (caller manages the transaction).
create or replace function public.enforce_chat_media_quota()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  owner_folder text;
  new_size bigint;
  old_size bigint := 0;
  live_total bigint;
begin
  if NEW.bucket_id <> 'chat-media' then return NEW; end if;
  owner_folder := (storage.foldername(NEW.name))[1];
  new_size := coalesce((NEW.metadata->>'size')::bigint, 0);
  if TG_OP = 'UPDATE' then
    old_size := coalesce((OLD.metadata->>'size')::bigint, 0);
  end if;
  if new_size > 67174400 then
    raise exception 'Media object exceeds the 64 MB single-object limit';
  end if;
  perform pg_advisory_xact_lock(hashtext('chat-media-budget:' || coalesce(owner_folder, '')));
  select coalesce(sum(coalesce((metadata->>'size')::bigint, 0)), 0) into live_total
    from storage.objects
    where bucket_id = 'chat-media'
      and (storage.foldername(name))[1] = owner_folder;
  if live_total - old_size + new_size > 314572800 then
    raise exception 'Storage budget exhausted';
  end if;
  return NEW;
end;
$$;

drop trigger if exists enforce_chat_media_quota on storage.objects;
create trigger enforce_chat_media_quota
  before insert or update on storage.objects
  for each row execute function public.enforce_chat_media_quota();

-- Live usage for the caller (storage dashboard / 60%-budget warnings).
create or replace function public.chat_media_usage()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in required'; end if;
  return (select jsonb_build_object(
    'bytes', coalesce(sum(coalesce((metadata->>'size')::bigint, 0)), 0),
    'objects', count(*))
    from storage.objects
    where bucket_id = 'chat-media'
      and (storage.foldername(name))[1] = me::text);
end;
$$;
revoke all on function public.chat_media_usage() from public, anon, authenticated;
grant execute on function public.chat_media_usage() to authenticated;
