-- =====================================================================
--  サーフィン行こ  追加SQL その11: プロフィール・自分だけのメモ名
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  変更点:
--   - プロフィール(自己紹介・よく行く場所・行く頻度)を自分で書ける。仲間全員が見られる
--   - 相手の名前に「自分だけに見えるメモ名」を付けられる(本人の登録名は変わらない)
-- =====================================================================

alter table public.members add column if not exists bio       text check (bio is null or char_length(bio) <= 500);
alter table public.members add column if not exists spots     text check (spots is null or char_length(spots) <= 200);
alter table public.members add column if not exists frequency text check (frequency is null or char_length(frequency) <= 100);

-- 読める列に追加(既存の列指定は残る)
grant select (bio, spots, frequency) on public.members to authenticated;

create or replace function public.update_my_profile(p_bio text, p_spots text, p_frequency text)
returns void
language plpgsql security definer
set search_path = public
as $$
declare v_me uuid := public.current_member_id();
begin
  if v_me is null then raise exception 'ログインしていません'; end if;
  update public.members
     set bio = nullif(trim(coalesce(p_bio, '')), ''),
         spots = nullif(trim(coalesce(p_spots, '')), ''),
         frequency = nullif(trim(coalesce(p_frequency, '')), '')
   where id = v_me;
end;
$$;
revoke all on function public.update_my_profile(text, text, text) from public, anon;
grant execute on function public.update_my_profile(text, text, text) to authenticated;

-- 自分だけのメモ名
create table if not exists public.member_aliases (
  owner_id  uuid not null references public.members(id) on delete cascade,
  target_id uuid not null references public.members(id) on delete cascade,
  alias     text not null check (char_length(trim(alias)) between 1 and 20),
  updated_at timestamptz not null default now(),
  primary key (owner_id, target_id)
);
alter table public.member_aliases enable row level security;
revoke all on public.member_aliases from anon, authenticated;
grant select, insert, update, delete on public.member_aliases to authenticated;

drop policy if exists member_aliases_own on public.member_aliases;
create policy member_aliases_own on public.member_aliases
  for all to authenticated
  using (owner_id = public.current_member_id())
  with check (owner_id = public.current_member_id());

select 'OK' as result;
