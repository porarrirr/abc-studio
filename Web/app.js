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
  function droppedLine(abc) {
    const lines = abc.split('\n');
    let inTune = false;
    for (let i = 0; i < lines.length; i++) {
      if (/^X:/.test(lines[i])) { inTune = true; continue; }
      if (!inTune || lines[i].trim()) continue;
      for (let j = i + 1; j < lines.length; j++) {
        if (!lines[j].trim()) continue;
        if (/^X:/.test(lines[j])) break;
        if (!/^%/.test(lines[j])) return j + 1;
      }
    }
    return 0;
  }
  function stripHtml(html) {
    const div = document.createElement('div'); div.innerHTML = html; return div.textContent;
  }
  function explainWarning(msg) {
    if (/Unknown character ignored/.test(msg)) return 'ABC として解釈できない文字があります（無視されます）';
    if (/Expected '\]'/.test(msg)) return "和音の [ ] が閉じられていません。']' を追加してください";
    if (/Unknown directive/.test(msg)) return 'abcjs が対応していない %% ディレクティブです（無視されます）';
    if (/Expected.*end of (slur|tie|grace|tuplet)/.test(msg)) return '括弧・装飾の対応が取れていません';
    return '';
  }
  function validateABC(abc) {
    const diags = [];
    const lines = abc.split('\n');
    const push = (line, col, severity, message) =>
      diags.push({line, col: col || 0, severity, message, context: line ? (lines[line - 1] || '').trim() : ''});
    if (!abc.trim()) { push(0,0,'error','ABC の内容が空です。X:、T:、M:、L:、K: を含むテキストを入力してください'); return diags; }
    const has = pattern => lines.some(l => pattern.test(l));
    if (!has(/^X:/)) push(0,0,'error','X:（曲番号）の行がありません。曲の先頭に「X:1」を書いてください');
    if (!has(/^K:\s*\S/)) push(0,0,'error','K:（調号）の行がありません。ヘッダの最後に「K:C」などを書いてください');
    if (!has(/^M:/)) push(0,0,'warn','M:（拍子）の行がありません。「M:4/4」などを追加してください');
    if (!has(/^L:/)) push(0,0,'warn','L:（基本の音長）の行がありません。「L:1/8」などを追加してください');
    if (!has(/^T:/)) push(0,0,'warn','T:（タイトル）の行がありません。タイトルなしで表示されます');
    const dropped = droppedLine(abc);
    if (dropped) push(dropped,0,'error','直前の空行で曲が終了したため、この行以降は読み込まれません。ABC では空行が曲の終わりを意味します。曲の途中の空行を削除してください');
    const defined = new Set(); const used = new Map(); let seenKey = false;
    lines.forEach((l, i) => {
      if (/^K:\s*\S/.test(l)) seenKey = true;
      let m = /^V:\s*([^\s]+)/.exec(l);
      if (m) { if (seenKey) { if (!used.has(m[1])) used.set(m[1], i + 1); } else defined.add(m[1]); }
      m = /^\[V:\s*([^\s\]]+)\]/.exec(l);
      if (m && !used.has(m[1])) used.set(m[1], i + 1);
    });
    used.forEach((ln, v) => { if (defined.size && !defined.has(v)) push(ln,0,'warn',`声部 "${v}" が V: で定義されていません。ヘッダに「V:${v}」を追加するか、表記を確認してください`); });
    const scoreIndex = lines.findIndex(l => /^%%score/.test(l));
    if (scoreIndex >= 0)
      lines[scoreIndex].replace(/^%%score\s*/,'').replace(/[(){}[\]|*]/g,' ').split(/\s+/).filter(v => v && !/=/.test(v))
        .forEach(v => { if (defined.size && !defined.has(v)) push(scoreIndex + 1,0,'warn',`%%score の声部 "${v}" が V: で定義されていません`); });
    try {
      const book = new ABCJS.TuneBook(abc);
      if (!book.tunes.length) push(0,0,'error','曲が見つかりませんでした。X: で始まり K: を含む曲が必要です');
      const xLines = []; lines.forEach((l, i) => { if (/^X:/.test(l)) xLines.push(i); });
      book.tunes.forEach((tune, ti) => {
        const tuneStart = (xLines[ti] ?? 0) + 1;
        const where = book.tunes.length > 1 ? `${ti + 1} 曲目 ` : '';
        let parsed;
        try { parsed = ABCJS.parseOnly(tune.abc)[0]; }
        catch (e) { push(tuneStart,0,'error',`${where}解析エラー: ${e.message}`); return; }
        (parsed.warnings || []).forEach(w => {
          const m = /^[^:]+:(\d+):(\d+):\s*(.*)$/s.exec(stripHtml(w));
          if (m) {
            const jp = explainWarning(m[3]);
            push(tuneStart + Number(m[1]) - 1, Number(m[2]),'warn',`${where}${jp ? jp + '。' : ''}abcjs: ${m[3]}`);
          } else push(tuneStart,0,'warn',where + stripHtml(w));
        });
        if (parsed && !(parsed.lines || []).some(l => l.staff)) push(tuneStart,0,'error',`${where}音符が見つかりません。K: の後に音符を書いてください`);
      });
    } catch (e) { push(0,0,'error',`解析エラー: ${e.message}`); }
    return diags.sort((a, b) => a.line - b.line || (a.severity === b.severity ? 0 : a.severity === 'error' ? -1 : 1));
  }
  function diagText(diags) {
    return diags.map(d => {
      const head = `${d.severity === 'error' ? 'エラー' : '警告'}${d.line ? ` ${d.line} 行目` : ''}${d.col ? ` ${d.col} 文字目` : ''}: ${d.message}`;
      return d.context ? `${head}\n    > ${d.context}` : head;
    }).join('\n');
  }
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    const ta = document.createElement('textarea');
    ta.value = text; ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
    document.body.appendChild(ta); ta.focus(); ta.select();
    const ok = document.execCommand('copy'); ta.remove();
    return ok ? Promise.resolve() : Promise.reject(new Error('copy failed'));
  }
  function renderDiagnostics(diags) {
    const list = $('diagnostics'); list.replaceChildren();
    $('diagPanel').hidden = !diags.length;
    $('diagSummary').textContent = diags.length
      ? `エラー ${diags.filter(d => d.severity === 'error').length} 件 · 警告 ${diags.filter(d => d.severity !== 'error').length} 件（タップで該当行へ）` : '';
    diags.forEach(d => {
      const li = document.createElement('li');
      li.className = d.severity === 'error' ? 'diag-error' : 'diag-warn';
      const head = document.createElement('div');
      const pos = document.createElement('span'); pos.className = 'diag-pos';
      pos.textContent = `${d.severity === 'error' ? 'エラー' : '警告'}${d.line ? ` ${d.line} 行目` : ''}${d.col ? ` ${d.col} 文字目` : ''}`;
      head.append(pos, document.createTextNode(d.message));
      li.appendChild(head);
      if (d.context) { const ctx = document.createElement('div'); ctx.className = 'diag-context'; ctx.textContent = d.context; li.appendChild(ctx); }
      if (d.line) li.addEventListener('click', () => jumpToLine(d.line));
      list.appendChild(li);
    });
  }
  function jumpToLine(line) {
    const ta = $('abcSource'); const lines = ta.value.split('\n');
    let offset = 0;
    for (let i = 0; i < line - 1 && i < lines.length; i++) offset += lines[i].length + 1;
    ta.focus(); ta.setSelectionRange(offset, offset + (lines[line - 1] || '').length);
    const lh = parseFloat(getComputedStyle(ta).lineHeight) || 22;
    ta.scrollTop = Math.max(0, (line - 4) * lh);
  }
  function validateSourceUI() { state.diags = validateABC($('abcSource').value.replace(/\r\n?/g,'\n')); renderDiagnostics(state.diags); }
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
    state.abc=abc.replace(/\r\n?/g,'\n');state.sourceName=filename || '';
    $('abcSource').value=state.abc;
    const diags = state.diags = validateABC(state.abc);
    renderDiagnostics(diags);
    const firstError = diags.find(d => d.severity === 'error');
    try {
      if (firstError) { selectTab('source'); throw new Error(`${firstError.line ? firstError.line + ' 行目: ' : ''}${firstError.message}`); }
      state.tunes = new ABCJS.TuneBook(state.abc).tunes;
      if (!state.tunes.length) throw new Error('曲が見つかりませんでした');
      const select=$('tuneSelect');select.replaceChildren();select.hidden=state.tunes.length<=1;
      state.tunes.forEach((tune,index)=>{const option=document.createElement('option');option.value=String(index);option.textContent=tune.title||`曲 ${index+1}`;select.appendChild(option)});
      renderTune(0);
      if (diags.some(d => d.severity === 'warn')) { status('読み込み完了（警告あり）'); toast('警告があります。「ABCを編集」タブで確認できます'); }
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
      if (!rendered[0].lines || !rendered[0].lines.some(line => line.staff)) throw new Error('音符が見つかりませんでした。ABC に音符が含まれているか確認してください');
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
  $('checkSource').addEventListener('click',validateSourceUI);
  $('copyDiags').addEventListener('click',()=>{
    const diags = state.diags || [];
    copyText('ABC Studio 診断結果\n' + diagText(diags)).then(()=>toast('診断結果をコピーしました'),()=>toast('コピーできませんでした'));
  });
  let lintTimer;
  $('abcSource').addEventListener('input',()=>{clearTimeout(lintTimer);lintTimer=setTimeout(validateSourceUI,500);});
  $('playButton').addEventListener('click',togglePlay);
  $('stopButton').addEventListener('click',stop);
  $('seek').addEventListener('input',event=>seek(event.target.value));
  $('speed').addEventListener('change',event=>setSpeed(event.target.value));
  $('tuneSelect').addEventListener('change',event=>renderTune(Number(event.target.value)));
  loadABC(EXAMPLE,'',false);
})();
