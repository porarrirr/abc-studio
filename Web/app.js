/* ABC Studio playback and notation UI. abcjs is pinned to 6.7.1. */
(() => {
  'use strict';
  const INSTRUMENTS = [
    {id:'piano', label:'ピアノ', program:0, icon:'♩'},
    {id:'guitar', label:'ギター', program:24, icon:'♮'},
    {id:'violin', label:'バイオリン', program:40, icon:'𝄞'},
    {id:'flute', label:'フルート', program:73, icon:'♫'},
    {id:'trumpet', label:'トランペット', program:56, icon:'♬'},
    {id:'bass', label:'ベース', program:33, icon:'𝄢'},
    {id:'drums', label:'ドラム', program:128, icon:'✳'},
    {id:'choir', label:'合唱', program:52, icon:'♪'}
  ];
  const EXAMPLE = `X:1
T:小さなアンサンブル
C:ABC Studio
M:4/4
L:1/4
Q:1/4=104
%%score melody harmony bass
V:melody clef=treble name="Violin"
V:harmony clef=treble name="Piano"
V:bass clef=bass name="Bass"
K:C
[V:melody] E F G c | B A G2 | A G F E | D4 |
[V:harmony] [CEG]2 [DFA]2 | [EGc]2 [CEG]2 | [FAc]2 [CEG]2 | [B,DG]4 |
[V:bass] C,2 G,2 | E,2 C,2 | F,2 C,2 | G,4 |`;

  const $ = id => document.getElementById(id);
  const state = {abc: EXAMPLE, tunes:[], voices:[], assignments:{}, visual:null, sequence:null, synth:null,
    timer:null, audioContext:null, playing:false, preparing:false, prepared:false, progress:0,
    duration:0, speed:100, generation:0, sourceName:'', selectedTune:0};
  let toastTimer;

  function toast(message) {
    const el = $('toast'); el.textContent = message; el.classList.add('show');
    clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove('show'), 3500);
  }
  function status(message) { $('playerStatus').textContent = message; }
  function formatTime(seconds) { seconds = Math.max(0, Math.floor(seconds || 0)); return `${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`; }
  function selectTab(name) {
    document.querySelectorAll('.tab').forEach(x => x.classList.toggle('active', x.dataset.tab === name));
    document.querySelectorAll('.pane').forEach(x => x.classList.toggle('active', x.id === name + 'Pane'));
  }
  function voicesIn(abc) {
    const found = []; const seen = new Set();
    for (const line of abc.split(/\r?\n/)) {
      const match = /^V:\s*([^\s]+)(.*)$/.exec(line);
      if (match && !seen.has(match[1])) {
        const nameMatch = /\bname=(?:"([^"]+)"|([^\s]+))/.exec(match[2]);
        found.push({id:match[1], name:nameMatch ? (nameMatch[1] || nameMatch[2]) : match[1]}); seen.add(match[1]);
      }
    }
    return found.length ? found : [{id:'main',name:'メロディー'}];
  }
  function guessInstrument(name) {
    const n = name.toLowerCase();
    if (/guitar|ギター/.test(n)) return 'guitar';
    if (/violin|fiddle|バイオリン/.test(n)) return 'violin';
    if (/flute|フルート/.test(n)) return 'flute';
    if (/trumpet|トランペット/.test(n)) return 'trumpet';
    if (/bass|ベース/.test(n)) return 'bass';
    if (/drum|percussion|ドラム/.test(n)) return 'drums';
    if (/choir|voice|vocal|合唱/.test(n)) return 'choir';
    return 'piano';
  }
  function renderParts() {
    const list = $('partList'); list.replaceChildren();
    state.voices.forEach((voice, index) => {
      const row = document.createElement('div'); row.className = 'part-row';
      const label = document.createElement('div'); label.className = 'part-label';
      const icon = document.createElement('span'); icon.className = 'part-icon';
      const inst = INSTRUMENTS.find(x => x.id === state.assignments[voice.id]) || INSTRUMENTS[0]; icon.textContent = inst.icon;
      const name = document.createElement('span'); name.textContent = voice.name;
      const sub = document.createElement('span'); sub.className = 'part-sub'; sub.textContent = `パート ${index+1}`; name.appendChild(sub);
      label.append(icon,name);
      const select = document.createElement('select'); select.setAttribute('aria-label', voice.name + 'の楽器');
      INSTRUMENTS.forEach(item => {const option = document.createElement('option');option.value=item.id;option.textContent=item.label;select.appendChild(option)});
      select.value = state.assignments[voice.id];
      select.addEventListener('change', () => {state.assignments[voice.id]=select.value;icon.textContent=INSTRUMENTS.find(x=>x.id===select.value).icon;invalidateAudio();toast('次の再生から音色を変更します')});
      row.append(label,select); list.appendChild(row);
    });
  }
  function clearCursor() {
    document.querySelectorAll('.abcjs-playing').forEach(el => el.classList.remove('abcjs-playing'));
    $('cursor').classList.remove('visible');
  }
  function cursorEvent(event) {
    clearCursor();
    if (!event) { ended(); return; }
    for (const item of event.elements || []) {
      const elements = Array.isArray(item) ? item : [item];
      for (const el of elements) if (el && el.classList) el.classList.add('abcjs-playing');
    }
    const cursor = $('cursor');
    const svg = $('paper').querySelector('svg');
    const scale = svg ? svg.getBoundingClientRect().width / svg.viewBox.baseVal.width : 1;
    const x = $('paper').offsetLeft + event.left * scale;
    const y = $('paper').offsetTop + event.top * scale;
    cursor.style.left = x + 'px';
    cursor.style.top = y + 'px';
    cursor.style.height = Math.max(15,(event.height || 0) * scale) + 'px';
    cursor.classList.add('visible');
    const scroll = $('scoreScroll');
    const top = y < scroll.scrollTop + 45 || y > scroll.scrollTop + scroll.clientHeight - 90
      ? Math.max(0,y - scroll.clientHeight * .28) : scroll.scrollTop;
    const left = x < scroll.scrollLeft + 35 || x > scroll.scrollLeft + scroll.clientWidth - 55
      ? Math.max(0,x - scroll.clientWidth * .35) : scroll.scrollLeft;
    if (top !== scroll.scrollTop || left !== scroll.scrollLeft)
      scroll.scrollTo({top,left,behavior:'smooth'});
  }
  function updateProgress(beat,totalBeats,totalTime) {
    const fraction = Math.max(0,Math.min(1,totalBeats ? beat/totalBeats : 0));
    state.progress = fraction;
    $('seek').value = Math.round(fraction * 1000);
    state.duration = totalTime / 1000 || state.duration;
    $('currentTime').textContent = formatTime(fraction * state.duration);
    $('totalTime').textContent = formatTime(state.duration);
  }
  function ended() {
    if (!state.playing) return;
    state.playing = false; state.progress = 0;
    $('seek').value = 0; $('currentTime').textContent='0:00';
    $('playButton').textContent='▶';$('playButton').setAttribute('aria-label','再生');status('再生完了');
    clearCursor(); if (state.synth) state.synth.stop(); if (state.timer) state.timer.stop();
  }
  function stop() {
    state.generation++;
    state.playing = false; if (state.synth) state.synth.stop(); if (state.timer) state.timer.stop();
    state.progress = 0; $('seek').value=0;$('currentTime').textContent='0:00';
    $('playButton').textContent='▶';$('playButton').setAttribute('aria-label','再生');clearCursor();status('停止');
  }
  function invalidateAudio() {
    stop(); state.prepared=false;state.synth=null;state.timer=null;
    state.duration=0;$('totalTime').textContent='0:00';
  }
  function loadABC(abc, filename, persist = true) {
    if (typeof abc !== 'string' || !abc.trim()) {toast('ABC の内容が空です');return;}
    if (!/(^|\n)K:\s*\S/m.test(abc)) {toast('K: で始まる調号の行が必要です');selectTab('source');$('abcSource').value=abc;return;}
    state.abc=abc.replace(/\r\n?/g,'\n');state.sourceName=filename || '';
    $('abcSource').value=state.abc;
    try {
      state.tunes = new ABCJS.TuneBook(state.abc).tunes;
      if (!state.tunes.length) throw new Error('曲が見つかりませんでした');
      const select=$('tuneSelect');select.replaceChildren();select.hidden=state.tunes.length<=1;
      state.tunes.forEach((tune,index)=>{const option=document.createElement('option');option.value=String(index);option.textContent=tune.title||`曲 ${index+1}`;select.appendChild(option)});
      renderTune(0);
      if (persist && window.webkit?.messageHandlers?.app)
        window.webkit.messageHandlers.app.postMessage({type:'save',abc:state.abc,filename:state.sourceName});
    } catch(error) {state.visual=null;status('読み込みエラー');toast(error.message || 'ABC を確認してください')}
  }
  function renderTune(index) {
    invalidateAudio();state.selectedTune=index;
    const tune=state.tunes[index];
    state.voices=voicesIn(tune.abc);const next={};
    state.voices.forEach(v => next[v.id]=state.assignments[v.id] || guessInstrument(v.name));state.assignments=next;
    const title = /^T:\s*(.+)$/m.exec(tune.abc);
    $('pieceTitle').textContent=title ? title[1].trim() : (state.sourceName || '無題の楽譜');
    const tuneCount=state.tunes.length>1 ? ` · ${index+1}/${state.tunes.length} 曲` : '';
    $('pieceSubtitle').textContent = (state.sourceName ? state.sourceName + ' · ' : '') + state.voices.length + ' パート' + tuneCount;
    try {
      $('paper').replaceChildren();
      const rendered = ABCJS.renderAbc('paper',tune.abc,{responsive:'resize',add_classes:true,staffwidth:1040,paddingtop:12,paddingbottom:12});
      if (!rendered.length || !$('paper').querySelector('svg')) throw new Error('楽譜を描画できませんでした');
      state.visual=rendered[0];renderParts();selectTab('score');status('準備完了');
    } catch(error) {state.visual=null;status('読み込みエラー');toast(error.message || 'ABC を確認してください')}
  }
  function programForTrack(index, track) {
    const nameEvent=track.find(event=>event.cmd==='text' && event.type==='name');
    const voice=(nameEvent && state.voices.find(v=>v.name===nameEvent.text))
      || state.voices[Math.min(index,state.voices.length-1)];
    return (INSTRUMENTS.find(x=>x.id===state.assignments[voice.id]) || INSTRUMENTS[0]).program;
  }
  async function prepare(generation) {
    if (!state.visual) throw new Error('楽譜を読み込んでください');
    if (!ABCJS.synth.supportsAudio()) throw new Error('この端末では音声再生を利用できません');
    state.audioContext = state.audioContext || new (window.AudioContext || window.webkitAudioContext)();
    await state.audioContext.resume();
    const sequence=state.visual.setUpAudio({chordsOff:true});
    sequence.tracks.forEach((track,index) => {
      const program=programForTrack(index,track);
      track.forEach(event => {if(event.cmd==='program') event.instrument=program; if(event.cmd==='note') event.instrument=program});
      if (!track.some(event=>event.cmd==='program')) track.unshift({cmd:'program',channel:program===128?10:0,instrument:program});
    });
    state.sequence=sequence;
    const baseMeasure=state.visual.millisecondsPerMeasure(sequence.tempo);
    const synth=new ABCJS.synth.CreateSynth();
    const result=await synth.init({audioContext:state.audioContext,sequence,
      millisecondsPerMeasure:baseMeasure*100/state.speed,
      options:{soundFontUrl:'soundfont/',soundFontVolumeMultiplier:2.4,fadeLength:120}});
    if (result.error && result.error.length) throw new Error('一部の音色を読み込めませんでした');
    const primed=await synth.prime();
    if (generation!==state.generation) {synth.stop();return false;}
    state.synth=synth;state.duration=primed.duration || 0;
    $('totalTime').textContent=formatTime(state.duration);
    const qpm=(sequence.tempo || 120)*state.speed/100;
    state.timer=new ABCJS.TimingCallbacks(state.visual,{qpm,beatSubdivisions:2,
      eventCallback:cursorEvent,beatCallback:updateProgress});
    state.prepared=true;return true;
  }
  async function togglePlay() {
    if (state.preparing) return;
    if (state.playing) {
      state.playing=false;state.synth.pause();state.timer.pause();
      $('playButton').textContent='▶';$('playButton').setAttribute('aria-label','再生');status('一時停止');return;
    }
    if (!state.visual) {toast('楽譜を読み込んでください');return;}
    try {
      if (!state.prepared) {
        state.preparing=true;status('音色を準備中…');$('playButton').disabled=true;
        const current=state.generation;
        const ok=await prepare(current);if (!ok) return;
        if (state.progress) {state.synth.seek(state.progress);state.timer.setProgress(state.progress);}
      }
      await state.audioContext.resume();
      state.synth.start();state.timer.start();state.playing=true;
      $('playButton').textContent='Ⅱ';$('playButton').setAttribute('aria-label','一時停止');status('再生中');
    } catch(error) {console.error(error);status('再生エラー');toast(error.message || '再生できませんでした');state.prepared=false;}
    finally {state.preparing=false;$('playButton').disabled=false;}
  }
  function seek(value) {
    const fraction=Math.max(0,Math.min(1,Number(value)/1000));state.progress=fraction;
    $('currentTime').textContent=formatTime(fraction*state.duration);
    if(state.prepared){state.synth.seek(fraction);state.timer.setProgress(fraction);}
  }
  function setSpeed(value) {
    const progress=state.progress;state.speed=Number(value);
    invalidateAudio();state.progress=progress;$('seek').value=Math.round(progress*1000);
    status('速度変更済み');
  }
  window.ABCStudio={importABC:loadABC};
  document.querySelectorAll('.tab').forEach(button=>button.addEventListener('click',()=>selectTab(button.dataset.tab)));
  $('openFile').addEventListener('click',()=>{
    if(window.webkit?.messageHandlers?.app) window.webkit.messageHandlers.app.postMessage({type:'open'});
    else {const input=document.createElement('input');input.type='file';input.accept='.abc,.txt,text/plain';input.onchange=async()=>{if(input.files[0])loadABC(await input.files[0].text(),input.files[0].name)};input.click();}
  });
  $('applySource').addEventListener('click',()=>loadABC($('abcSource').value,state.sourceName));
  $('playButton').addEventListener('click',togglePlay);
  $('stopButton').addEventListener('click',stop);
  $('seek').addEventListener('input',event=>seek(event.target.value));
  $('speed').addEventListener('change',event=>setSpeed(event.target.value));
  $('tuneSelect').addEventListener('change',event=>renderTune(Number(event.target.value)));
  loadABC(EXAMPLE,'',false);
})();
