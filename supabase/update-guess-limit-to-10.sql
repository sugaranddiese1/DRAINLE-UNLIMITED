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
