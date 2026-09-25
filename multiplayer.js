(() => {
  const songs=(window.SONGS||[]).map((song,index)=>({...song,id:index}));
  const config=window.BLAIDLE_SUPABASE||{};
  const configured=Boolean(config.url&&config.anonKey&&window.supabase?.createClient);
  const client=configured?window.supabase.createClient(config.url,config.anonKey):null;
  const $=selector=>document.querySelector(selector);
  const els={soloTab:$("#soloTab"),multiplayerTab:$("#multiplayerTab"),soloView:$("#soloView"),multiplayerView:$("#multiplayerView"),brandTagline:$("#brandTagline"),versusTab:$("#versusTab"),coopTab:$("#coopTab"),challengeTab:$("#challengeTab"),home:$("#multiplayerHome"),modeLabel:$("#multiplayerModeLabel"),title:$("#multiplayerTitle"),description:$("#multiplayerDescription"),backendNotice:$("#backendNotice"),playerName:$("#playerName"),versusOptions:$("#versusOptions"),create:$("#createRoomButton"),join:$("#joinRoomButton"),joinCode:$("#joinCode"),message:$("#multiplayerMessage"),lobby:$("#roomLobby"),roomCode:$("#roomCode"),connection:$("#connectionStatus"),copyInvite:$("#copyInviteButton"),copyCode:$("#copyCodeButton"),hostRole:$("#hostRole"),guestRole:$("#guestRole"),hostName:$("#hostName"),guestName:$("#guestName"),hostStatus:$("#hostStatus"),guestStatus:$("#guestStatus"),challengePicker:$("#challengeSongPicker"),challengeSearch:$("#challengeSongSearch"),challengeSuggestions:$("#challengeSuggestions"),challengeLock:$("#lockChallengeSongButton"),challengeStatus:$("#challengeSongStatus"),challengeWaiting:$("#challengeWaiting"),ready:$("#readyButton"),start:$("#startMatchButton"),leave:$("#leaveRoomButton"),lobbyMessage:$("#lobbyMessage"),game:$("#multiplayerGame"),challengeWatcher:$("#challengeWatcher"),roundLabel:$("#roundLabelMultiplayer"),matchScore:$("#matchScore"),opponentName:$("#opponentName"),opponentProgress:$("#opponentProgress"),coopLock:$("#coopLockStatus"),searchWrap:$("#multiplayerSearchWrap"),search:$("#multiplayerSongSearch"),suggestions:$("#multiplayerSuggestions"),guess:$("#multiplayerGuessButton"),guessStatus:$("#multiplayerGuessStatus"),gameLeave:$("#multiplayerLeaveButton"),coopDecision:$("#coopDecision"),coopChoices:$("#coopChoices"),coopDecisionStatus:$("#coopDecisionStatus"),gameMessage:$("#multiplayerGameMessage"),boardLayout:$("#versusBoardLayout"),ownBoard:$("#multiplayerOwnBoard"),opponentBoard:$("#opponentBoard"),opponentBoardName:$("#opponentBoardName"),opponentFeedbackRows:$("#opponentFeedbackRows"),rows:$("#multiplayerGuessRows"),results:$("#roundResults"),resultTitle:$("#multiplayerResultTitle"),answer:$("#multiplayerAnswer"),comparison:$("#resultComparison"),resultSummary:$("#multiplayerResultSummary"),share:$("#multiplayerShareButton"),next:$("#nextRoundButton"),rematch:$("#rematchButton"),return:$("#returnMultiplayerButton")};
  const normalize=value=>String(value||"").toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g," ").trim();
  const MAX_GUESSES=10;
  let mode="versus",matchLength=1,user=null,room=null,channel=null,selected=null,challengeSelected=null,history=[],opponentHistory=[],matchSummary=[],activeSuggestion=-1,challengeSuggestion=-1,autoSubmitting=false;

  function showView(view){const multiplayer=view==="multiplayer";els.soloView.hidden=multiplayer;els.multiplayerView.hidden=!multiplayer;els.soloTab.classList.toggle("active",!multiplayer);els.multiplayerTab.classList.toggle("active",multiplayer);els.soloTab.setAttribute("aria-selected",String(!multiplayer));els.multiplayerTab.setAttribute("aria-selected",String(multiplayer));els.brandTagline.textContent=multiplayer?"two players · one mystery song":"guess the drain gang song · unlimited"}
  function setMode(next,force=false){
    if(room&&!force)return;
    mode=next;
    const coop=mode==="coop";
    const challenge=mode==="challenge";
    els.versusTab.classList.toggle("active",mode==="versus");
    els.coopTab.classList.toggle("active",coop);
    els.challengeTab.classList.toggle("active",challenge);
    els.versusTab.setAttribute("aria-selected",String(mode==="versus"));
    els.coopTab.setAttribute("aria-selected",String(coop));
    els.challengeTab.setAttribute("aria-selected",String(challenge));
    els.modeLabel.textContent=challenge?"pick for a friend":coop?"two player team":"1 versus 1";
    els.title.textContent=challenge?"challenge":coop?"co-op":"versus";
    els.description.textContent=challenge?"Choose a secret song. Your friend gets ten guesses to find it.":coop?"Lock answers separately, agree on one guess, and solve together.":"The same mystery song. Separate boards. Fewest guesses wins.";
    els.create.textContent=challenge?"create challenge room":coop?"create co-op room":"create game";
    els.join.textContent=challenge?"join challenge room":coop?"join co-op room":"join game";
    els.versusOptions.hidden=mode!=="versus";
    els.message.textContent="";
  }
  function setScreen(name){els.home.hidden=name!=="home";els.lobby.hidden=name!=="lobby";els.game.hidden=name!=="game";els.results.hidden=name!=="results"}
  function setMessage(text,error=false){els.message.textContent=text;els.message.style.color=error?"var(--red-text)":""}
  function playerName(){const value=els.playerName.value.trim().slice(0,20);if(value)localStorage.setItem("blaidle-player-name",value);return value}
  async function ensureBackend(){if(!configured){els.backendNotice.hidden=false;els.backendNotice.textContent="Multiplayer needs the Supabase project values in supabase-config.js. Solo mode is still available.";throw new Error("multiplayer backend is not configured")}if(user)return user;const current=await client.auth.getSession();if(current.data.session)user=current.data.session.user;else{const signed=await client.auth.signInAnonymously();if(signed.error)throw signed.error;user=signed.data.user}return user}
  async function rpc(name,args={}){const response=await client.rpc(name,args);if(response.error)throw response.error;return response.data}
  function isHost(){return room&&user&&room.host_id===user.id}
  function ownSide(){return isHost()?"host":"guest"}
  function otherSide(){return isHost()?"guest":"host"}
  function ownName(){return isHost()?room.host_name:room.guest_name}
  function otherName(){return isHost()?room.guest_name:room.host_name}
  function songById(id){return songs[Number(id)]||null}
  function roomUrl(){const url=new URL(location.href);url.searchParams.set("multiplayer",room.mode);url.searchParams.set("room",room.code);return url.toString()}

  async function createRoom(){try{const name=playerName();if(!name)return setMessage("enter a display name",true);await ensureBackend();els.create.disabled=true;const code=await rpc("create_blaidle_room",{p_mode:mode,p_name:name,p_match_length:mode==="versus"?matchLength:1,p_catalog_size:songs.length});await enterRoom(code)}catch(error){setMessage(error.message||"could not create room",true)}finally{els.create.disabled=false}}
  async function joinRoom(){try{const name=playerName();const code=els.joinCode.value.trim().toUpperCase();if(!name)return setMessage("enter a display name",true);if(code.length!==5)return setMessage("enter a five-character room code",true);await ensureBackend();els.join.disabled=true;await rpc("join_blaidle_room",{p_code:code,p_name:name});await enterRoom(code)}catch(error){setMessage(error.message||"could not join room",true)}finally{els.join.disabled=false}}
  async function enterRoom(code){await loadRoom(code);mode=room.mode;setMode(mode,true);history=[];opponentHistory=[];matchSummary=[];challengeSelected=null;setScreen(room.status==="lobby"?"lobby":room.status==="playing"?"game":"results");subscribeRoom();history=await loadHistory();opponentHistory=await loadOpponentHistory();matchSummary=await loadMatchSummary();renderRoom();const url=new URL(location.href);url.searchParams.set("multiplayer",mode);url.searchParams.set("room",room.code);window.history.replaceState({},"",url)}
  async function loadRoom(code){const response=await client.from("blaidle_rooms").select("*").eq("code",code.toUpperCase()).single();if(response.error)throw response.error;room=response.data}
  async function loadHistory(){if(!room||room.status==="lobby")return[];try{return await rpc("get_blaidle_guess_history",{p_code:room.code})||[]}catch{return[]}}
  async function loadOpponentHistory(){if(!room||room.status==="lobby"||!(room.mode==="versus"||(room.mode==="challenge"&&isHost())))return[];try{return await rpc("get_blaidle_opponent_progress",{p_code:room.code})||[]}catch{return[]}}
  async function loadMatchSummary(){if(!room||room.mode!=="versus"||room.status!=="match_results")return[];try{return await rpc("get_blaidle_match_summary",{p_code:room.code})||[]}catch{return[]}}
  function subscribeRoom(){if(channel)client.removeChannel(channel);channel=client.channel(`blaidle-room-${room.code}`,{config:{presence:{key:user.id}}}).on("postgres_changes",{event:"*",schema:"public",table:"blaidle_rooms",filter:`code=eq.${room.code}`},async payload=>{if(payload.eventType==="DELETE"){room=null;history=[];opponentHistory=[];matchSummary=[];setScreen("home");setMessage("The other player closed the room.");return}room=payload.new;history=await loadHistory();opponentHistory=await loadOpponentHistory();matchSummary=await loadMatchSummary();renderRoom()}).on("presence",{event:"sync"},()=>{const count=Object.keys(channel.presenceState()).length;els.connection.textContent=count>1?"2 connected":"1 connected";els.connection.classList.toggle("connected",count>1)}).subscribe(async status=>{if(status==="SUBSCRIBED"){await channel.track({name:ownName(),online_at:new Date().toISOString()});els.connection.textContent="connected";els.connection.classList.add("connected")}else if(status==="CHANNEL_ERROR"||status==="TIMED_OUT"){els.connection.textContent="reconnecting";els.connection.classList.remove("connected")}})}

  function renderRoom(){if(!room)return;const status=room.status;if(status==="lobby"){setScreen("lobby");renderLobby()}else if(status==="playing"){setScreen("game");renderGame()}else{setScreen("results");renderResults()}}
  function renderLobby(){
    const challenge=room.mode==="challenge";
    const host=isHost();
    const targetSet=Boolean(room.challenge_target_set);
    els.roomCode.textContent=room.code;
    els.hostRole.textContent=challenge?"selector":"player 1";
    els.guestRole.textContent=challenge?"guesser":"player 2";
    els.hostName.textContent=room.host_name||"waiting...";
    els.guestName.textContent=room.guest_name||"waiting for player";
    els.hostStatus.textContent=challenge&&!targetSet?"choose a song":room.host_ready?"ready":"not ready";
    els.guestStatus.textContent=room.guest_ready?"ready":room.guest_id?"not ready":"not connected";
    els.hostStatus.classList.toggle("ready",room.host_ready);
    els.guestStatus.classList.toggle("ready",room.guest_ready);
    els.challengePicker.hidden=!challenge||!host;
    els.challengeWaiting.hidden=!challenge||host;
    if(challenge){
      els.challengeStatus.textContent=targetSet?"secret song locked ✓ · search again to replace it":"Only you will see the song you select.";
      els.challengeWaiting.textContent=targetSet?"secret song locked ✓ · get ready to guess":"the selector is choosing a secret song...";
    }
    const ready=host?room.host_ready:room.guest_ready;
    els.ready.textContent=ready?"not ready":"ready";
    els.ready.disabled=challenge&&host&&!targetSet;
    els.start.hidden=!host;
    els.start.disabled=!(room.host_ready&&room.guest_ready)&&true;
    if(challenge&&!targetSet)els.start.disabled=true;
    if(challenge){
      if(!targetSet)els.lobbyMessage.textContent=host?"Choose and lock a secret song before getting ready.":"Waiting for the selector to lock a song.";
      else if(!room.guest_id)els.lobbyMessage.textContent="Secret song locked. Share the room code with the guesser.";
      else if(room.host_ready&&room.guest_ready)els.lobbyMessage.textContent=host?"Both players are ready. Start the challenge.":"Both players are ready. Waiting for the selector to start.";
      else els.lobbyMessage.textContent="The challenge starts after both players are ready.";
    }else{
      els.lobbyMessage.textContent=room.host_ready&&room.guest_ready?(host?"Both players are ready. Start when you are ready.":"Both players are ready. Waiting for the host."):"The game starts after both players are ready.";
    }
  }
  function renderGame(){
    const versus=room.mode==="versus";
    const coop=room.mode==="coop";
    const challenge=room.mode==="challenge";
    const selector=challenge&&isHost();
    const other=otherSide();
    const otherCount=room[`${other}_guess_count`]||0;
    const otherOutcome=room[`${other}_outcome`]||"playing";
    const challengeCount=room.guest_guess_count||0;
    els.roundLabel.textContent=versus?`round ${room.current_round} of ${room.match_length}`:challenge?"song challenge":"co-op round";
    els.matchScore.textContent=versus?`${room.host_name} ${room.host_score} — ${room.guest_score} ${room.guest_name}`:challenge?`${room.host_name} chose · ${room.guest_name} guesses`:`${room.host_name} + ${room.guest_name}`;
    els.opponentName.textContent=versus?(otherName()||"opponent"):challenge?(selector?(room.guest_name||"guesser"):"your progress"):"team progress";
    els.opponentProgress.textContent=versus?`guess ${otherCount} · ${otherOutcome}`:challenge?`${challengeCount}/${MAX_GUESSES} · ${room.guest_outcome}`:`${room.coop_guess_count||0}/${MAX_GUESSES} guesses`;
    els.rows.innerHTML="";
    history.forEach((item,index)=>els.rows.appendChild(renderHistoryRow(item,index)));
    renderOpponentBoard();
    const count=coop?(room.coop_guess_count||0):challenge?challengeCount:(room[`${ownSide()}_guess_count`]||0);
    const remaining=Math.max(0,MAX_GUESSES-count);
    els.guessStatus.textContent=selector?`${challengeCount}/${MAX_GUESSES} guesses used`:`${remaining} guess${remaining===1?"":"es"} remaining`;
    const ownFinished=(versus&&room[`${ownSide()}_outcome`]!=="playing")||(challenge&&room.guest_outcome!=="playing");
    const ownLocked=coop&&room[`${ownSide()}_locked`];
    const deciding=coop&&room.coop_proposal_host!==null&&room.coop_proposal_guest!==null;
    els.searchWrap.hidden=selector;
    els.guess.hidden=selector;
    els.ownBoard.hidden=selector;
    els.challengeWatcher.hidden=!selector;
    if(selector)els.challengeWatcher.textContent=`your secret song is locked · ${room.guest_name||"the guesser"} has used ${challengeCount} of ${MAX_GUESSES} guesses`;
    els.search.disabled=selector||ownFinished||ownLocked||deciding;
    els.guess.disabled=selector||ownFinished||ownLocked||deciding||!selected;
    els.coopLock.hidden=!coop||!ownLocked||deciding;
    els.coopLock.textContent="your guess locked ✓ · waiting for teammate...";
    els.coopDecision.hidden=!deciding;
    els.gameMessage.textContent=versus&&ownFinished?`You are ${room[`${ownSide()}_outcome`]}. Waiting for your opponent...`:"";
    if(deciding)renderCoopDecision();else{els.coopChoices.innerHTML="";autoSubmitting=false}
  }
  function renderOpponentBoard(){
    const show=room.mode==="versus"||(room.mode==="challenge"&&isHost());
    const selectorView=room.mode==="challenge"&&isHost();
    els.opponentBoard.hidden=!show;
    els.boardLayout.classList.toggle("has-opponent",show);
    els.boardLayout.classList.toggle("selector-view",selectorView);
    if(!show)return;
    els.opponentBoardName.textContent=selectorView?(room.guest_name||"guesser"):(otherName()||"opponent");
    els.opponentFeedbackRows.innerHTML="";
    if(!opponentHistory.length){
      const empty=document.createElement("p");
      empty.className="opponent-board-empty";
      empty.textContent=selectorView?"waiting for the guesser's first guess...":"waiting for their first guess...";
      els.opponentFeedbackRows.appendChild(empty);
      return;
    }
    opponentHistory.forEach((states,index)=>{
      const row=document.createElement("div");
      row.className="opponent-feedback-row";
      row.setAttribute("aria-label",`hidden guess ${index+1}: ${states.join(", ")}`);
      const number=document.createElement("span");
      number.className="opponent-guess-number";
      number.textContent=String(index+1);
      const cells=document.createElement("div");
      cells.className="opponent-feedback-cells";
      states.forEach(state=>{
        const cell=document.createElement("i");
        cell.className=`opponent-feedback-cell opponent-${state}`;
        cell.setAttribute("aria-hidden","true");
        cells.appendChild(cell);
      });
      row.append(number,cells);
      els.opponentFeedbackRows.appendChild(row);
    });
  }

  function renderCoopDecision(){const ids=[room.coop_proposal_host,room.coop_proposal_guest];const same=ids[0]===ids[1];els.coopChoices.innerHTML="";for(const id of [...new Set(ids)]){const song=songById(id);const button=document.createElement("button");button.className="coop-choice";button.textContent=song?`${song.title} — ${song.artist}`:`song ${id}`;const ownConfirm=room[`${ownSide()}_confirm`];button.classList.toggle("selected",Number(ownConfirm)===Number(id));button.addEventListener("click",()=>confirmCoop(id));els.coopChoices.appendChild(button)}if(same){els.coopDecisionStatus.textContent="Both players chose the same song. Submitting...";if(isHost()&&!autoSubmitting){autoSubmitting=true;confirmCoop(ids[0],true)}}else{const hostVote=room.host_confirm,guestVote=room.guest_confirm;els.coopDecisionStatus.textContent=hostVote===null&&guestVote===null?"Both choices are revealed. Each player must select the same team answer.":hostVote!==null&&guestVote!==null&&hostVote!==guestVote?"You chose different answers. Choose again to agree.":"One choice is locked. Waiting for the other player."}}
  function renderHistoryRow(item,index){const song=songById(item.song_id)||{title:"unknown",artist:"",features:"",album:"",year:"",track:""};const row=document.createElement("div");row.className="guess-grid guess-row"+(item.correct?" is-correct":"");row.style.animationDelay=`${index*35}ms`;const states=item.feedback||["far","far","far","far","far","far"];row.append(makeCell(song.title,"song",stateClass(states[0])),makeCell(song.artist,"artist",stateClass(states[1])),makeCell(song.features||"none","features",stateClass(states[2])),makeCell(song.album,"album",stateClass(states[3])),makeCell(song.year,"year",stateClass(states[4]),item.year_arrow),makeCell(song.track,"track #",stateClass(states[5]),item.track_arrow));return row}
  function stateClass(state){return state==="exact"?"feedback-exact":state==="close"?"feedback-close":"feedback-far"}
  function makeCell(value,label,className="",arrow=""){const cell=document.createElement("div");cell.className=`cell ${className}`;cell.dataset.label=label;const text=document.createElement("span");text.textContent=value||"none";cell.appendChild(text);if(arrow){const a=document.createElement("span");a.className="arrow";a.textContent=arrow;cell.appendChild(a)}return cell}

  function showChallengeSuggestions(){
    challengeSelected=null;
    els.challengeLock.disabled=true;
    challengeSuggestion=-1;
    const query=els.challengeSearch.value;
    if(!normalize(query)){els.challengeSuggestions.hidden=true;return}
    const found=songs.filter(song=>matches(query,song)).slice(0,10);
    els.challengeSuggestions.innerHTML="";
    for(const song of found){
      const button=document.createElement("button");
      button.type="button";
      button.className="suggestion";
      button.setAttribute("role","option");
      button.innerHTML="<strong></strong><span></span>";
      button.querySelector("strong").textContent=song.title;
      button.querySelector("span").textContent=[song.artist,song.album,song.year].filter(Boolean).join(" · ");
      button.addEventListener("click",()=>selectChallengeSong(song));
      els.challengeSuggestions.appendChild(button);
    }
    els.challengeSuggestions.hidden=!found.length;
  }
  function selectChallengeSong(song){
    challengeSelected=song;
    els.challengeSearch.value=`${song.title} — ${song.artist}`;
    els.challengeSuggestions.hidden=true;
    els.challengeLock.disabled=false;
    els.challengeLock.focus();
  }
  async function lockChallengeSong(){
    if(!challengeSelected||!room||room.mode!=="challenge"||!isHost())return;
    const song=challengeSelected;
    els.challengeLock.disabled=true;
    try{
      await rpc("set_blaidle_challenge_song",{p_code:room.code,p_song_id:song.id});
      challengeSelected=null;
      els.challengeSearch.value="";
      els.challengeSuggestions.hidden=true;
      await refreshRoom();
    }catch(error){
      els.challengeStatus.textContent=error.message||"secret song could not be locked";
      els.challengeLock.disabled=false;
    }
  }

  function matches(query,song){const q=normalize(query);return q&&(normalize(song.title).includes(q)||normalize(song.artist).includes(q)||normalize(song.album).includes(q))}
  function showSuggestions(){selected=null;els.guess.disabled=true;activeSuggestion=-1;const query=els.search.value;if(!normalize(query)){els.suggestions.hidden=true;return}const used=new Set(history.map(item=>Number(item.song_id)));const found=songs.filter(song=>matches(query,song)&&!used.has(song.id)).slice(0,10);els.suggestions.innerHTML="";for(const song of found){const button=document.createElement("button");button.type="button";button.className="suggestion";button.setAttribute("role","option");button.innerHTML="<strong></strong><span></span>";button.querySelector("strong").textContent=song.title;button.querySelector("span").textContent=[song.artist,song.album,song.year].filter(Boolean).join(" · ");button.addEventListener("click",()=>selectSong(song));els.suggestions.appendChild(button)}els.suggestions.hidden=!found.length}
  function selectSong(song){selected=song;els.search.value=song.title;els.suggestions.hidden=true;els.guess.disabled=false;els.guess.focus()}
  async function submitGuess(){if(!selected||!room)return;const song=selected;selected=null;els.search.value="";els.guess.disabled=true;try{if(room.mode==="versus")await rpc("submit_blaidle_versus_guess",{p_code:room.code,p_song_id:song.id});else if(room.mode==="challenge")await rpc("submit_blaidle_challenge_guess",{p_code:room.code,p_song_id:song.id});else await rpc("lock_blaidle_coop_proposal",{p_code:room.code,p_song_id:song.id});await refreshRoom()}catch(error){els.gameMessage.textContent=error.message||"guess could not be submitted"}}
  async function confirmCoop(songId,automatic=false){try{await rpc("confirm_blaidle_coop_guess",{p_code:room.code,p_song_id:Number(songId)});if(!automatic)els.coopDecisionStatus.textContent="choice locked · waiting for teammate";await refreshRoom()}catch(error){els.gameMessage.textContent=error.message||"team choice could not be submitted";autoSubmitting=false}}
  async function refreshRoom(){await loadRoom(room.code);history=await loadHistory();opponentHistory=await loadOpponentHistory();matchSummary=await loadMatchSummary();renderRoom()}

  function renderResults(){
    const answer=songById(room.answer_song_id);
    els.answer.textContent=answer?`${answer.title} by ${answer.artist}`:"round complete";
    els.comparison.innerHTML="";
    const matchDone=room.status==="match_results";
    if(room.mode==="versus"){
      const winner=room.round_winner;
      els.resultTitle.textContent=matchDone?(room.host_score===room.guest_score?"match tied":"match complete"):winner==="tie"?"round tied":`${winner==="host"?room.host_name:room.guest_name} wins the round`;
      for(const side of ["host","guest"]){
        const card=document.createElement("div");
        card.className="result-player"+(winner===side?" winner":"");
        const outcome=room[`${side}_outcome`];
        const guesses=room[`${side}_guess_count`];
        card.innerHTML="<strong></strong><span></span>";
        card.querySelector("strong").textContent=room[`${side}_name`];
        card.querySelector("span").textContent=outcome==="solved"?`solved in ${guesses}/${MAX_GUESSES}`:"not solved";
        els.comparison.appendChild(card);
      }
      if(matchDone&&matchSummary.length){
        const rounds=document.createElement("div");
        rounds.className="match-history";
        rounds.innerHTML=matchSummary.map(item=>`<div><strong>round ${item.round}</strong><span>${escapeHtml(room.host_name)}: ${item.host_solved?`${item.host_count}/${MAX_GUESSES}`:"failed"}</span><span>${escapeHtml(room.guest_name)}: ${item.guest_solved?`${item.guest_count}/${MAX_GUESSES}`:"failed"}</span></div>`).join("");
        els.comparison.appendChild(rounds);
      }
      els.resultSummary.textContent=`score: ${room.host_score} — ${room.guest_score}`;
      els.next.hidden=matchDone||!isHost();
      els.next.textContent="next round";
      els.rematch.hidden=!matchDone||!isHost();
      els.rematch.textContent="rematch";
    }else if(room.mode==="challenge"){
      const solved=room.guest_outcome==="solved";
      els.resultTitle.textContent=solved?`${room.guest_name} solved it ✓`:"challenge complete";
      els.comparison.innerHTML=`<div class="result-player"><strong>${escapeHtml(room.host_name)}</strong><span>selected the secret song</span></div><div class="result-player ${solved?"winner":""}"><strong>${escapeHtml(room.guest_name)}</strong><span>${solved?`solved in ${room.guest_guess_count}/${MAX_GUESSES}`:`not solved in ${MAX_GUESSES} guesses`}</span></div>`;
      els.resultSummary.textContent=solved?`solved in ${room.guest_guess_count} ${room.guest_guess_count===1?"try":"tries"}`:"the song was not guessed";
      els.next.hidden=true;
      els.rematch.hidden=!isHost();
      els.rematch.textContent="choose another song";
    }else{
      els.resultTitle.textContent=room.coop_outcome==="solved"?"co-op solved ✓":"co-op complete";
      els.comparison.innerHTML=`<div class="result-player winner"><strong>${escapeHtml(room.host_name)} + ${escapeHtml(room.guest_name)}</strong><span>${room.coop_outcome==="solved"?`solved in ${room.coop_guess_count}/${MAX_GUESSES}`:"not solved"}</span></div>`;
      els.resultSummary.textContent="one team · one result";
      els.next.hidden=true;
      els.rematch.hidden=!isHost();
      els.rematch.textContent="play again";
    }
  }
  function escapeHtml(value){return String(value||"").replace(/[&<>"']/g,char=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[char]))}

  async function toggleReady(){try{const ready=room[`${ownSide()}_ready`];await rpc("set_blaidle_ready",{p_code:room.code,p_ready:!ready});await refreshRoom()}catch(error){els.lobbyMessage.textContent=error.message}}
  async function startMatch(){try{els.start.disabled=true;await rpc("start_blaidle_match",{p_code:room.code});await refreshRoom()}catch(error){els.lobbyMessage.textContent=error.message;els.start.disabled=false}}
  async function nextRound(){try{await rpc("next_blaidle_round",{p_code:room.code});history=[];opponentHistory=[];await refreshRoom()}catch(error){els.resultSummary.textContent=error.message}}
  async function rematch(){try{await rpc("rematch_blaidle",{p_code:room.code});history=[];opponentHistory=[];await refreshRoom()}catch(error){els.resultSummary.textContent=error.message}}
  async function leaveRoom(){const code=room?.code;try{if(configured&&code)await rpc("leave_blaidle_room",{p_code:code})}catch{}if(channel&&client)client.removeChannel(channel);channel=null;room=null;history=[];opponentHistory=[];matchSummary=[];selected=null;setScreen("home");const url=new URL(location.href);url.searchParams.delete("room");url.searchParams.delete("multiplayer");window.history.replaceState({},"",url);setMode(mode)}
  async function copyText(text,button){try{await navigator.clipboard.writeText(text);const old=button.textContent;button.textContent="copied!";setTimeout(()=>button.textContent=old,1400)}catch{els.lobbyMessage.textContent="could not copy"}}
  function shareText(){
    if(!room)return"";
    const answer=songById(room.answer_song_id);
    const answerLine=answer?`${answer.title} — ${answer.artist}`:"";
    if(room.mode==="challenge"){
      const result=room.guest_outcome==="solved"?`${room.guest_name} solved it in ${room.guest_guess_count}/${MAX_GUESSES}`:`${room.guest_name} did not solve it in ${MAX_GUESSES} guesses`;
      return`blaidle challenge\n\n${result}\nselected by ${room.host_name}\n\n${answerLine}`;
    }
    if(room.mode==="coop")return`blaidle co-op\n\n${room.host_name} + ${room.guest_name}\n${room.coop_outcome==="solved"?`solved in ${room.coop_guess_count}/${MAX_GUESSES}`:"not solved"}\n\n${answerLine}`;
    return`blaidle versus\n\n${room.host_name} ${room.host_score} — ${room.guest_score} ${room.guest_name}\nround ${room.current_round}/${room.match_length}\n\n${answerLine}`;
  }
  async function shareResults(){const text=shareText();try{if(navigator.share)await navigator.share({text});else await copyText(text,els.share)}catch(error){if(error?.name!=="AbortError")els.resultSummary.textContent="could not share results"}}

  els.soloTab.addEventListener("click",()=>showView("solo"));
  els.multiplayerTab.addEventListener("click",()=>showView("multiplayer"));
  els.versusTab.addEventListener("click",()=>setMode("versus"));
  els.coopTab.addEventListener("click",()=>setMode("coop"));
  els.challengeTab.addEventListener("click",()=>setMode("challenge"));
  document.querySelectorAll("[data-rounds]").forEach(button=>button.addEventListener("click",()=>{matchLength=Number(button.dataset.rounds);document.querySelectorAll("[data-rounds]").forEach(item=>item.classList.toggle("active",item===button))}));
  els.create.addEventListener("click",createRoom);
  els.join.addEventListener("click",joinRoom);
  els.joinCode.addEventListener("input",()=>els.joinCode.value=els.joinCode.value.toUpperCase().replace(/[^A-Z0-9]/g,"").slice(0,5));
  els.copyInvite.addEventListener("click",()=>copyText(roomUrl(),els.copyInvite));
  els.copyCode.addEventListener("click",()=>copyText(room.code,els.copyCode));
  els.ready.addEventListener("click",toggleReady);
  els.start.addEventListener("click",startMatch);
  els.leave.addEventListener("click",leaveRoom);
  els.gameLeave.addEventListener("click",leaveRoom);
  els.next.addEventListener("click",nextRound);
  els.rematch.addEventListener("click",rematch);
  els.return.addEventListener("click",leaveRoom);
  els.share.addEventListener("click",shareResults);
  els.search.addEventListener("input",showSuggestions);
  els.search.addEventListener("keydown",event=>{const items=[...els.suggestions.querySelectorAll(".suggestion")];if(event.key==="ArrowDown"||event.key==="ArrowUp"){event.preventDefault();if(items.length){activeSuggestion=(activeSuggestion+(event.key==="ArrowDown"?1:-1)+items.length)%items.length;items.forEach((item,index)=>item.classList.toggle("active",index===activeSuggestion));items[activeSuggestion].scrollIntoView({block:"nearest"})}}else if(event.key==="Enter"){event.preventDefault();if(!els.suggestions.hidden&&activeSuggestion>=0)items[activeSuggestion].click();else if(selected)submitGuess()}else if(event.key==="Escape")els.suggestions.hidden=true});
  els.guess.addEventListener("click",submitGuess);
  els.challengeSearch.addEventListener("input",showChallengeSuggestions);
  els.challengeSearch.addEventListener("keydown",event=>{const items=[...els.challengeSuggestions.querySelectorAll(".suggestion")];if(event.key==="ArrowDown"||event.key==="ArrowUp"){event.preventDefault();if(items.length){challengeSuggestion=(challengeSuggestion+(event.key==="ArrowDown"?1:-1)+items.length)%items.length;items.forEach((item,index)=>item.classList.toggle("active",index===challengeSuggestion));items[challengeSuggestion].scrollIntoView({block:"nearest"})}}else if(event.key==="Enter"){event.preventDefault();if(!els.challengeSuggestions.hidden&&challengeSuggestion>=0)items[challengeSuggestion].click();else if(challengeSelected)lockChallengeSong()}else if(event.key==="Escape")els.challengeSuggestions.hidden=true});
  els.challengeLock.addEventListener("click",lockChallengeSong);
  document.addEventListener("click",event=>{if(!event.target.closest("#multiplayerSearchWrap"))els.suggestions.hidden=true;if(!event.target.closest("#challengeSearchWrap"))els.challengeSuggestions.hidden=true});

  els.playerName.value=localStorage.getItem("blaidle-player-name")||"";
  if(!configured){
    els.backendNotice.hidden=false;
    els.backendNotice.textContent="Multiplayer is installed but needs Supabase configuration before rooms can be created.";
    els.create.disabled=true;
    els.join.disabled=true;
  }
  const params=new URLSearchParams(location.search);
  if(params.get("multiplayer")){
    showView("multiplayer");
    const requestedMode=["versus","coop","challenge"].includes(params.get("multiplayer"))?params.get("multiplayer"):"versus";
    setMode(requestedMode);
    if(params.get("room")){
      els.joinCode.value=params.get("room").toUpperCase();
      setMessage("Enter your name, then join the invited room.");
    }
  }else setMode("versus");
})();
