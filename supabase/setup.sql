-- Blaidle multiplayer backend for Supabase.
-- Run this file once in the Supabase SQL editor, then run seed-songs.sql.
-- Enable Anonymous Sign-Ins in Authentication > Providers before testing.

create extension if not exists pgcrypto;

create table if not exists public.blaidle_songs (
  id integer primary key,
  title text not null,
  artist text not null,
  features text not null default '',
  album text not null,
  track_number integer not null,
  release_year integer not null
);

create table if not exists public.blaidle_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9]{5}$'),
  mode text not null check (mode in ('versus','coop')),
  match_length integer not null default 1 check (match_length in (1,3,5)),
  catalog_size integer not null,
  host_id uuid not null,
  guest_id uuid,
  host_name text not null,
  guest_name text,
  host_ready boolean not null default false,
  guest_ready boolean not null default false,
  status text not null default 'lobby' check (status in ('lobby','playing','round_results','match_results','results')),
  current_round integer not null default 0,
  host_score integer not null default 0,
  guest_score integer not null default 0,
  host_guess_count integer not null default 0,
  guest_guess_count integer not null default 0,
  host_outcome text not null default 'playing' check (host_outcome in ('playing','solved','failed')),
  guest_outcome text not null default 'playing' check (guest_outcome in ('playing','solved','failed')),
  round_winner text check (round_winner in ('host','guest','tie')),
  answer_song_id integer references public.blaidle_songs(id),
  coop_guess_count integer not null default 0,
  coop_outcome text not null default 'playing' check (coop_outcome in ('playing','solved','failed')),
  host_locked boolean not null default false,
  guest_locked boolean not null default false,
  coop_proposal_host integer references public.blaidle_songs(id),
  coop_proposal_guest integer references public.blaidle_songs(id),
  host_confirm integer references public.blaidle_songs(id),
  guest_confirm integer references public.blaidle_songs(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.blaidle_targets (
  room_id uuid not null references public.blaidle_rooms(id) on delete cascade,
  round_number integer not null,
  song_id integer not null references public.blaidle_songs(id),
  primary key (room_id,round_number)
);

create table if not exists public.blaidle_guesses (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.blaidle_rooms(id) on delete cascade,
  round_number integer not null,
  user_id uuid,
  shared boolean not null default false,
  guess_number integer not null,
  song_id integer not null references public.blaidle_songs(id),
  feedback jsonb not null,
  correct boolean not null,
  created_at timestamptz not null default now(),
  unique(room_id,round_number,user_id,guess_number)
);

create table if not exists public.blaidle_proposals (
  room_id uuid not null references public.blaidle_rooms(id) on delete cascade,
  round_number integer not null,
  user_id uuid not null,
  song_id integer not null references public.blaidle_songs(id),
  primary key(room_id,round_number,user_id)
);

alter table public.blaidle_rooms enable row level security;
alter table public.blaidle_guesses enable row level security;
alter table public.blaidle_targets enable row level security;
alter table public.blaidle_proposals enable row level security;
alter table public.blaidle_songs enable row level security;

drop policy if exists "songs are readable" on public.blaidle_songs;
create policy "songs are readable" on public.blaidle_songs for select using (true);
drop policy if exists "room members can read" on public.blaidle_rooms;
create policy "room members can read" on public.blaidle_rooms for select to authenticated using (auth.uid()=host_id or auth.uid()=guest_id);
drop policy if exists "players read their own or shared guesses" on public.blaidle_guesses;
create policy "players read their own or shared guesses" on public.blaidle_guesses for select to authenticated using (
  user_id=auth.uid() or (shared and exists(select 1 from public.blaidle_rooms r where r.id=room_id and (r.host_id=auth.uid() or r.guest_id=auth.uid())))
);

revoke all on public.blaidle_targets from anon,authenticated;
revoke all on public.blaidle_proposals from anon,authenticated;
grant select on public.blaidle_songs to authenticated;
grant select on public.blaidle_rooms to authenticated;
grant select on public.blaidle_guesses to authenticated;

alter table public.blaidle_rooms replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.blaidle_rooms;
exception when duplicate_object then null;
end $$;

create or replace function public.blaidle_touch_room() returns trigger language plpgsql as $$
begin new.updated_at=now(); return new; end $$;
drop trigger if exists blaidle_room_updated on public.blaidle_rooms;
create trigger blaidle_room_updated before update on public.blaidle_rooms for each row execute function public.blaidle_touch_room();

create or replace function public.blaidle_room_code() returns text language plpgsql as $$
declare chars text:='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; result text:=''; i integer;
begin for i in 1..5 loop result:=result||substr(chars,1+floor(random()*length(chars))::integer,1); end loop; return result; end $$;

create or replace function public.blaidle_feedback(p_guess integer,p_target integer) returns jsonb
language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'states',jsonb_build_array(
      case when g.id=t.id then 'exact' else 'far' end,
      case when lower(g.artist)=lower(t.artist) then 'exact' else 'far' end,
      case when lower(g.features)=lower(t.features) then 'exact' else 'far' end,
      case when lower(g.album)=lower(t.album) then 'exact' else 'far' end,
      case when g.release_year=t.release_year then 'exact' when abs(g.release_year-t.release_year)<=2 then 'close' else 'far' end,
      case when g.track_number=t.track_number then 'exact' when abs(g.track_number-t.track_number)<=2 then 'close' else 'far' end
    ),
    'year_arrow',case when g.release_year=t.release_year then '' when g.release_year<t.release_year then '↑' else '↓' end,
    'track_arrow',case when g.track_number=t.track_number then '' when g.track_number<t.track_number then '↑' else '↓' end
  ) from public.blaidle_songs g cross join public.blaidle_songs t where g.id=p_guess and t.id=p_target
$$;

create or replace function public.create_blaidle_room(p_mode text,p_name text,p_match_length integer,p_catalog_size integer) returns text
language plpgsql security definer set search_path=public as $$
declare v_code text; tries integer:=0;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  if p_mode not in ('versus','coop') then raise exception 'Invalid mode'; end if;
  if p_match_length not in (1,3,5) then raise exception 'Invalid match length'; end if;
  if char_length(trim(p_name)) not between 1 and 20 then raise exception 'Enter a display name'; end if;
  if p_catalog_size<>(select count(*) from public.blaidle_songs) then raise exception 'Song catalog needs to be synchronized'; end if;
  loop v_code:=public.blaidle_room_code(); exit when not exists(select 1 from public.blaidle_rooms where code=v_code); tries:=tries+1; if tries>20 then raise exception 'Could not generate room code'; end if; end loop;
  insert into public.blaidle_rooms(code,mode,match_length,catalog_size,host_id,host_name) values(v_code,p_mode,case when p_mode='coop' then 1 else p_match_length end,p_catalog_size,auth.uid(),trim(p_name));
  return v_code;
end $$;

create or replace function public.join_blaidle_room(p_code text,p_name text) returns text
language plpgsql security definer set search_path=public as $$
declare v_room public.blaidle_rooms;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_room from public.blaidle_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found'; end if;
  if v_room.status<>'lobby' then raise exception 'This match has already started'; end if;
  if v_room.host_id=auth.uid() then return v_room.code; end if;
  if v_room.guest_id is not null and v_room.guest_id<>auth.uid() then raise exception 'Room is full'; end if;
  update public.blaidle_rooms set guest_id=auth.uid(),guest_name=trim(p_name),guest_ready=false where id=v_room.id;
  return v_room.code;
end $$;

create or replace function public.set_blaidle_ready(p_code text,p_ready boolean) returns void
language plpgsql security definer set search_path=public as $$
begin
  update public.blaidle_rooms set host_ready=case when host_id=auth.uid() then p_ready else host_ready end,guest_ready=case when guest_id=auth.uid() then p_ready else guest_ready end where code=upper(p_code) and status='lobby' and (host_id=auth.uid() or guest_id=auth.uid());
  if not found then raise exception 'Room is unavailable'; end if;
end $$;

create or replace function public.start_blaidle_match(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare v_room public.blaidle_rooms; v_target integer;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if v_room.host_id<>auth.uid() then raise exception 'Only the host can start'; end if;
  if v_room.status<>'lobby' or not v_room.host_ready or not v_room.guest_ready then raise exception 'Both players must be ready'; end if;
  select id into v_target from public.blaidle_songs order by random() limit 1;
  insert into public.blaidle_targets(room_id,round_number,song_id) values(v_room.id,1,v_target);
  update public.blaidle_rooms set status='playing',current_round=1,host_guess_count=0,guest_guess_count=0,host_outcome='playing',guest_outcome='playing',round_winner=null,answer_song_id=null,coop_guess_count=0,coop_outcome='playing',host_locked=false,guest_locked=false,coop_proposal_host=null,coop_proposal_guest=null,host_confirm=null,guest_confirm=null where id=v_room.id;
end $$;

create or replace function public.submit_blaidle_versus_guess(p_code text,p_song_id integer) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_room public.blaidle_rooms; v_target integer; v_side text; v_count integer; v_correct boolean; v_feedback jsonb; v_host_score integer; v_guest_score integer; v_winner text; v_status text;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if v_room.mode<>'versus' or v_room.status<>'playing' then raise exception 'Round is not accepting guesses'; end if;
  v_side:=case when v_room.host_id=auth.uid() then 'host' when v_room.guest_id=auth.uid() then 'guest' else null end;
  if v_side is null then raise exception 'You are not in this room'; end if;
  if (v_side='host' and v_room.host_outcome<>'playing') or (v_side='guest' and v_room.guest_outcome<>'playing') then raise exception 'Your round is complete'; end if;
  if not exists(select 1 from public.blaidle_songs where id=p_song_id) then raise exception 'Song not found'; end if;
  if exists(select 1 from public.blaidle_guesses where room_id=v_room.id and round_number=v_room.current_round and user_id=auth.uid() and song_id=p_song_id) then raise exception 'You already guessed that song'; end if;
  select song_id into v_target from public.blaidle_targets where room_id=v_room.id and round_number=v_room.current_round;
  select count(*)::integer+1 into v_count from public.blaidle_guesses where room_id=v_room.id and round_number=v_room.current_round and user_id=auth.uid();
  v_correct:=p_song_id=v_target; v_feedback:=public.blaidle_feedback(p_song_id,v_target);
  insert into public.blaidle_guesses(room_id,round_number,user_id,shared,guess_number,song_id,feedback,correct) values(v_room.id,v_room.current_round,auth.uid(),false,v_count,p_song_id,v_feedback,v_correct);
  if v_side='host' then update public.blaidle_rooms set host_guess_count=v_count,host_outcome=case when v_correct then 'solved' when v_count>=10 then 'failed' else 'playing' end where id=v_room.id;
  else update public.blaidle_rooms set guest_guess_count=v_count,guest_outcome=case when v_correct then 'solved' when v_count>=10 then 'failed' else 'playing' end where id=v_room.id; end if;
  select * into v_room from public.blaidle_rooms where id=v_room.id;
  if v_room.host_outcome<>'playing' and v_room.guest_outcome<>'playing' then
    if v_room.host_outcome='solved' and v_room.guest_outcome='solved' then v_winner:=case when v_room.host_guess_count<v_room.guest_guess_count then 'host' when v_room.guest_guess_count<v_room.host_guess_count then 'guest' else 'tie' end;
    elsif v_room.host_outcome='solved' then v_winner:='host'; elsif v_room.guest_outcome='solved' then v_winner:='guest'; else v_winner:='tie'; end if;
    v_host_score:=v_room.host_score+case when v_winner='host' then 1 else 0 end; v_guest_score:=v_room.guest_score+case when v_winner='guest' then 1 else 0 end;
    v_status:=case when v_room.current_round>=v_room.match_length or v_host_score>v_room.match_length/2 or v_guest_score>v_room.match_length/2 then 'match_results' else 'round_results' end;
    update public.blaidle_rooms set host_score=v_host_score,guest_score=v_guest_score,round_winner=v_winner,answer_song_id=v_target,status=v_status where id=v_room.id;
  end if;
  return v_feedback||jsonb_build_object('correct',v_correct,'guess_count',v_count);
end $$;

create or replace function public.lock_blaidle_coop_proposal(p_code text,p_song_id integer) returns void
language plpgsql security definer set search_path=public as $$
declare v_room public.blaidle_rooms; v_host_song integer; v_guest_song integer;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if v_room.mode<>'coop' or v_room.status<>'playing' then raise exception 'Co-op round is not accepting guesses'; end if;
  if auth.uid() not in (v_room.host_id,v_room.guest_id) then raise exception 'You are not in this room'; end if;
  if (v_room.host_id=auth.uid() and v_room.host_locked) or (v_room.guest_id=auth.uid() and v_room.guest_locked) then raise exception 'Your proposal is already locked'; end if;
  insert into public.blaidle_proposals(room_id,round_number,user_id,song_id) values(v_room.id,v_room.current_round,auth.uid(),p_song_id) on conflict(room_id,round_number,user_id) do update set song_id=excluded.song_id;
  update public.blaidle_rooms set host_locked=case when host_id=auth.uid() then true else host_locked end,guest_locked=case when guest_id=auth.uid() then true else guest_locked end where id=v_room.id;
  select * into v_room from public.blaidle_rooms where id=v_room.id;
  if v_room.host_locked and v_room.guest_locked then
    select song_id into v_host_song from public.blaidle_proposals where room_id=v_room.id and round_number=v_room.current_round and user_id=v_room.host_id;
    select song_id into v_guest_song from public.blaidle_proposals where room_id=v_room.id and round_number=v_room.current_round and user_id=v_room.guest_id;
    update public.blaidle_rooms set coop_proposal_host=v_host_song,coop_proposal_guest=v_guest_song where id=v_room.id;
  end if;
end $$;

create or replace function public.confirm_blaidle_coop_guess(p_code text,p_song_id integer) returns void
language plpgsql security definer set search_path=public as $$
declare v_room public.blaidle_rooms; v_target integer; v_count integer; v_correct boolean; v_feedback jsonb; v_commit boolean:=false;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if v_room.mode<>'coop' or v_room.status<>'playing' or v_room.coop_proposal_host is null or v_room.coop_proposal_guest is null then raise exception 'Both proposals must be revealed first'; end if;
  if auth.uid() not in (v_room.host_id,v_room.guest_id) then raise exception 'You are not in this room'; end if;
  if p_song_id not in (v_room.coop_proposal_host,v_room.coop_proposal_guest) then raise exception 'Choose one of the proposed songs'; end if;
  if v_room.coop_proposal_host=v_room.coop_proposal_guest then v_commit:=true;
  else
    update public.blaidle_rooms set host_confirm=case when host_id=auth.uid() then p_song_id else host_confirm end,guest_confirm=case when guest_id=auth.uid() then p_song_id else guest_confirm end where id=v_room.id;
    select * into v_room from public.blaidle_rooms where id=v_room.id;
    v_commit:=v_room.host_confirm is not null and v_room.host_confirm=v_room.guest_confirm;
  end if;
  if v_commit then
    select song_id into v_target from public.blaidle_targets where room_id=v_room.id and round_number=v_room.current_round;
    v_count:=v_room.coop_guess_count+1; v_correct:=p_song_id=v_target; v_feedback:=public.blaidle_feedback(p_song_id,v_target);
    insert into public.blaidle_guesses(room_id,round_number,user_id,shared,guess_number,song_id,feedback,correct) values(v_room.id,v_room.current_round,null,true,v_count,p_song_id,v_feedback,v_correct);
    delete from public.blaidle_proposals where room_id=v_room.id and round_number=v_room.current_round;
    if v_correct or v_count>=10 then update public.blaidle_rooms set coop_guess_count=v_count,coop_outcome=case when v_correct then 'solved' else 'failed' end,status='results',answer_song_id=v_target,host_locked=false,guest_locked=false,coop_proposal_host=null,coop_proposal_guest=null,host_confirm=null,guest_confirm=null where id=v_room.id;
    else update public.blaidle_rooms set coop_guess_count=v_count,host_locked=false,guest_locked=false,coop_proposal_host=null,coop_proposal_guest=null,host_confirm=null,guest_confirm=null where id=v_room.id; end if;
  end if;
end $$;

create or replace function public.get_blaidle_guess_history(p_code text) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('song_id',g.song_id,'feedback',g.feedback->'states','year_arrow',g.feedback->>'year_arrow','track_arrow',g.feedback->>'track_arrow','correct',g.correct) order by g.guess_number),'[]'::jsonb)
  from public.blaidle_guesses g join public.blaidle_rooms r on r.id=g.room_id
  where r.code=upper(p_code) and g.round_number=r.current_round and (r.host_id=auth.uid() or r.guest_id=auth.uid()) and (g.shared or g.user_id=auth.uid())
$$;

create or replace function public.get_blaidle_opponent_progress(p_code text) returns jsonb
language sql stable security definer set search_path=public as $
  with room as (
    select * from public.blaidle_rooms
    where code=upper(p_code) and mode='versus' and (host_id=auth.uid() or guest_id=auth.uid())
  )
  select coalesce(jsonb_agg(g.feedback->'states' order by g.guess_number),'[]'::jsonb)
  from public.blaidle_guesses g cross join room r
  where g.room_id=r.id
    and g.round_number=r.current_round
    and g.user_id=case when r.host_id=auth.uid() then r.guest_id else r.host_id end
$;

create or replace function public.get_blaidle_match_summary(p_code text) returns jsonb
language sql stable security definer set search_path=public as $$
  with room as (
    select * from public.blaidle_rooms where code=upper(p_code) and (host_id=auth.uid() or guest_id=auth.uid())
  ), rounds as (
    select generate_series(1,(select current_round from room)) as round_number
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'round',rounds.round_number,
    'host_count',(select count(*) from public.blaidle_guesses g,room r where g.room_id=r.id and g.round_number=rounds.round_number and g.user_id=r.host_id),
    'guest_count',(select count(*) from public.blaidle_guesses g,room r where g.room_id=r.id and g.round_number=rounds.round_number and g.user_id=r.guest_id),
    'host_solved',coalesce((select bool_or(g.correct) from public.blaidle_guesses g,room r where g.room_id=r.id and g.round_number=rounds.round_number and g.user_id=r.host_id),false),
    'guest_solved',coalesce((select bool_or(g.correct) from public.blaidle_guesses g,room r where g.room_id=r.id and g.round_number=rounds.round_number and g.user_id=r.guest_id),false)
  ) order by rounds.round_number),'[]'::jsonb) from rounds
$$;

create or replace function public.next_blaidle_round(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare v_room public.blaidle_rooms; v_round integer; v_target integer;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if v_room.host_id<>auth.uid() or v_room.mode<>'versus' or v_room.status<>'round_results' then raise exception 'Next round is not available'; end if;
  v_round:=v_room.current_round+1; select id into v_target from public.blaidle_songs order by random() limit 1;
  insert into public.blaidle_targets(room_id,round_number,song_id) values(v_room.id,v_round,v_target);
  update public.blaidle_rooms set current_round=v_round,status='playing',host_guess_count=0,guest_guess_count=0,host_outcome='playing',guest_outcome='playing',round_winner=null,answer_song_id=null where id=v_room.id;
end $$;

create or replace function public.rematch_blaidle(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare v_room public.blaidle_rooms; v_target integer;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if v_room.host_id<>auth.uid() or v_room.status not in ('match_results','results') then raise exception 'Rematch is not available'; end if;
  delete from public.blaidle_targets where room_id=v_room.id; delete from public.blaidle_guesses where room_id=v_room.id; delete from public.blaidle_proposals where room_id=v_room.id;
  select id into v_target from public.blaidle_songs order by random() limit 1; insert into public.blaidle_targets(room_id,round_number,song_id) values(v_room.id,1,v_target);
  update public.blaidle_rooms set status='playing',current_round=1,host_score=0,guest_score=0,host_guess_count=0,guest_guess_count=0,host_outcome='playing',guest_outcome='playing',round_winner=null,answer_song_id=null,coop_guess_count=0,coop_outcome='playing',host_locked=false,guest_locked=false,coop_proposal_host=null,coop_proposal_guest=null,host_confirm=null,guest_confirm=null where id=v_room.id;
end $$;

create or replace function public.leave_blaidle_room(p_code text) returns void
language plpgsql security definer set search_path=public as $$
begin delete from public.blaidle_rooms where code=upper(p_code) and (host_id=auth.uid() or guest_id=auth.uid()); end $$;

revoke all on function public.blaidle_feedback(integer,integer) from public,anon,authenticated;
revoke execute on function public.create_blaidle_room(text,text,integer,integer),public.join_blaidle_room(text,text),public.set_blaidle_ready(text,boolean),public.start_blaidle_match(text),public.submit_blaidle_versus_guess(text,integer),public.lock_blaidle_coop_proposal(text,integer),public.confirm_blaidle_coop_guess(text,integer),public.get_blaidle_guess_history(text),public.get_blaidle_opponent_progress(text),public.get_blaidle_match_summary(text),public.next_blaidle_round(text),public.rematch_blaidle(text),public.leave_blaidle_room(text) from public,anon;
grant execute on function public.create_blaidle_room(text,text,integer,integer),public.join_blaidle_room(text,text),public.set_blaidle_ready(text,boolean),public.start_blaidle_match(text),public.submit_blaidle_versus_guess(text,integer),public.lock_blaidle_coop_proposal(text,integer),public.confirm_blaidle_coop_guess(text,integer),public.get_blaidle_guess_history(text),public.get_blaidle_opponent_progress(text),public.get_blaidle_match_summary(text),public.next_blaidle_round(text),public.rematch_blaidle(text),public.leave_blaidle_room(text) to authenticated;
