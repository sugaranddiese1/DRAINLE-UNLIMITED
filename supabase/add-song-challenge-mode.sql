-- Blaidle song challenge migration.
-- Run this entire file once in the Supabase SQL Editor.
-- It also reapplies the ten-guess multiplayer limit safely.

-- Run this once in the Supabase SQL Editor for an existing Blaidle installation.
-- It changes the server-enforced multiplayer guess limit from 6 to 10.

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

revoke execute on function public.submit_blaidle_versus_guess(text,integer),public.lock_blaidle_coop_proposal(text,integer),public.confirm_blaidle_coop_guess(text,integer) from public,anon;
grant execute on function public.submit_blaidle_versus_guess(text,integer),public.lock_blaidle_coop_proposal(text,integer),public.confirm_blaidle_coop_guess(text,integer) to authenticated;

alter table public.blaidle_rooms add column if not exists challenge_target_set boolean not null default false;
alter table public.blaidle_rooms drop constraint if exists blaidle_rooms_mode_check;
alter table public.blaidle_rooms add constraint blaidle_rooms_mode_check check (mode in ('versus','coop','challenge'));

create or replace function public.create_blaidle_room(p_mode text,p_name text,p_match_length integer,p_catalog_size integer) returns text
language plpgsql security definer set search_path=public as $fn$
declare v_code text; tries integer:=0;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  if p_mode not in ('versus','coop','challenge') then raise exception 'Invalid mode'; end if;
  if p_match_length not in (1,3,5) then raise exception 'Invalid match length'; end if;
  if char_length(trim(p_name)) not between 1 and 20 then raise exception 'Enter a display name'; end if;
  if p_catalog_size<>(select count(*) from public.blaidle_songs) then raise exception 'Song catalog needs to be synchronized'; end if;
  loop
    v_code:=public.blaidle_room_code();
    exit when not exists(select 1 from public.blaidle_rooms where code=v_code);
    tries:=tries+1;
    if tries>20 then raise exception 'Could not generate room code'; end if;
  end loop;
  insert into public.blaidle_rooms(code,mode,match_length,catalog_size,host_id,host_name)
  values(v_code,p_mode,case when p_mode='versus' then p_match_length else 1 end,p_catalog_size,auth.uid(),trim(p_name));
  return v_code;
end
$fn$;

create or replace function public.set_blaidle_ready(p_code text,p_ready boolean) returns void
language plpgsql security definer set search_path=public as $fn$
declare v_room public.blaidle_rooms;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if not found or auth.uid() not in (v_room.host_id,v_room.guest_id) then raise exception 'Room is unavailable'; end if;
  if v_room.status<>'lobby' then raise exception 'Room is unavailable'; end if;
  if v_room.mode='challenge' and v_room.host_id=auth.uid() and p_ready and not v_room.challenge_target_set then
    raise exception 'Choose a secret song first';
  end if;
  update public.blaidle_rooms
  set host_ready=case when host_id=auth.uid() then p_ready else host_ready end,
      guest_ready=case when guest_id=auth.uid() then p_ready else guest_ready end
  where id=v_room.id;
end
$fn$;

create or replace function public.set_blaidle_challenge_song(p_code text,p_song_id integer) returns void
language plpgsql security definer set search_path=public as $fn$
declare v_room public.blaidle_rooms;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if not found or v_room.host_id<>auth.uid() then raise exception 'Only the selector can choose the song'; end if;
  if v_room.mode<>'challenge' or v_room.status<>'lobby' then raise exception 'The secret song cannot be changed now'; end if;
  if not exists(select 1 from public.blaidle_songs where id=p_song_id) then raise exception 'Song not found'; end if;
  delete from public.blaidle_targets where room_id=v_room.id and round_number=1;
  insert into public.blaidle_targets(room_id,round_number,song_id) values(v_room.id,1,p_song_id);
  update public.blaidle_rooms set challenge_target_set=true,host_ready=false where id=v_room.id;
end
$fn$;

create or replace function public.start_blaidle_match(p_code text) returns void
language plpgsql security definer set search_path=public as $fn$
declare v_room public.blaidle_rooms; v_target integer;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if v_room.host_id<>auth.uid() then raise exception 'Only the host can start'; end if;
  if v_room.status<>'lobby' or not v_room.host_ready or not v_room.guest_ready then raise exception 'Both players must be ready'; end if;
  if v_room.mode='challenge' then
    select song_id into v_target from public.blaidle_targets where room_id=v_room.id and round_number=1;
    if not v_room.challenge_target_set or v_target is null then raise exception 'Choose a secret song first'; end if;
  else
    select id into v_target from public.blaidle_songs order by random() limit 1;
    insert into public.blaidle_targets(room_id,round_number,song_id) values(v_room.id,1,v_target);
  end if;
  update public.blaidle_rooms
  set status='playing',current_round=1,host_guess_count=0,guest_guess_count=0,
      host_outcome='playing',guest_outcome='playing',round_winner=null,answer_song_id=null,
      coop_guess_count=0,coop_outcome='playing',host_locked=false,guest_locked=false,
      coop_proposal_host=null,coop_proposal_guest=null,host_confirm=null,guest_confirm=null
  where id=v_room.id;
end
$fn$;

create or replace function public.submit_blaidle_challenge_guess(p_code text,p_song_id integer) returns jsonb
language plpgsql security definer set search_path=public as $fn$
declare v_room public.blaidle_rooms; v_target integer; v_count integer; v_correct boolean; v_feedback jsonb;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if not found or v_room.mode<>'challenge' or v_room.status<>'playing' then raise exception 'Challenge is not accepting guesses'; end if;
  if v_room.guest_id is null or v_room.guest_id<>auth.uid() then raise exception 'Only the guesser can submit guesses'; end if;
  if v_room.guest_outcome<>'playing' then raise exception 'The challenge is complete'; end if;
  if not exists(select 1 from public.blaidle_songs where id=p_song_id) then raise exception 'Song not found'; end if;
  if exists(
    select 1 from public.blaidle_guesses
    where room_id=v_room.id and round_number=1 and user_id=auth.uid() and song_id=p_song_id
  ) then raise exception 'You already guessed that song'; end if;
  select song_id into v_target from public.blaidle_targets where room_id=v_room.id and round_number=1;
  if v_target is null then raise exception 'Secret song is unavailable'; end if;
  select count(*)::integer+1 into v_count
  from public.blaidle_guesses where room_id=v_room.id and round_number=1 and user_id=auth.uid();
  v_correct:=p_song_id=v_target;
  v_feedback:=public.blaidle_feedback(p_song_id,v_target);
  insert into public.blaidle_guesses(room_id,round_number,user_id,shared,guess_number,song_id,feedback,correct)
  values(v_room.id,1,auth.uid(),false,v_count,p_song_id,v_feedback,v_correct);
  if v_correct or v_count>=10 then
    update public.blaidle_rooms
    set guest_guess_count=v_count,
        guest_outcome=case when v_correct then 'solved' else 'failed' end,
        round_winner=case when v_correct then 'guest' else 'host' end,
        answer_song_id=v_target,
        status='results'
    where id=v_room.id;
  else
    update public.blaidle_rooms set guest_guess_count=v_count where id=v_room.id;
  end if;
  return v_feedback||jsonb_build_object('correct',v_correct,'guess_count',v_count);
end
$fn$;

create or replace function public.get_blaidle_opponent_progress(p_code text) returns jsonb
language sql stable security definer set search_path=public as $fn$
  with room as (
    select * from public.blaidle_rooms
    where code=upper(p_code)
      and mode in ('versus','challenge')
      and (host_id=auth.uid() or guest_id=auth.uid())
  )
  select coalesce(jsonb_agg(g.feedback->'states' order by g.guess_number),'[]'::jsonb)
  from public.blaidle_guesses g cross join room r
  where g.room_id=r.id
    and g.round_number=r.current_round
    and g.user_id=case when r.host_id=auth.uid() then r.guest_id else r.host_id end
$fn$;

create or replace function public.rematch_blaidle(p_code text) returns void
language plpgsql security definer set search_path=public as $fn$
declare v_room public.blaidle_rooms; v_target integer;
begin
  select * into v_room from public.blaidle_rooms where code=upper(p_code) for update;
  if v_room.host_id<>auth.uid() or v_room.status not in ('match_results','results') then raise exception 'Rematch is not available'; end if;
  delete from public.blaidle_targets where room_id=v_room.id;
  delete from public.blaidle_guesses where room_id=v_room.id;
  delete from public.blaidle_proposals where room_id=v_room.id;
  if v_room.mode='challenge' then
    update public.blaidle_rooms
    set status='lobby',current_round=0,host_score=0,guest_score=0,
        host_guess_count=0,guest_guess_count=0,host_outcome='playing',guest_outcome='playing',
        round_winner=null,answer_song_id=null,challenge_target_set=false,
        host_ready=false,guest_ready=false
    where id=v_room.id;
    return;
  end if;
  select id into v_target from public.blaidle_songs order by random() limit 1;
  insert into public.blaidle_targets(room_id,round_number,song_id) values(v_room.id,1,v_target);
  update public.blaidle_rooms
  set status='playing',current_round=1,host_score=0,guest_score=0,
      host_guess_count=0,guest_guess_count=0,host_outcome='playing',guest_outcome='playing',
      round_winner=null,answer_song_id=null,coop_guess_count=0,coop_outcome='playing',
      host_locked=false,guest_locked=false,coop_proposal_host=null,coop_proposal_guest=null,
      host_confirm=null,guest_confirm=null
  where id=v_room.id;
end
$fn$;

revoke execute on function public.set_blaidle_challenge_song(text,integer),public.submit_blaidle_challenge_guess(text,integer),public.get_blaidle_opponent_progress(text) from public,anon;
grant execute on function public.set_blaidle_challenge_song(text,integer),public.submit_blaidle_challenge_guess(text,integer),public.get_blaidle_opponent_progress(text) to authenticated;
