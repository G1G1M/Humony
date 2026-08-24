// HarmonyUp 전용 VexFlow 렌더링 로직. Swift(VexFlowScoreView)가 window.renderScore(data)를
// 직접 호출한다 — data는 이미 JS 객체 리터럴로 평가되는 JSON(문자열 아님)이라 파싱이 필요 없다.
//
// data 형식:
// {
//   voices: [ { clef: "treble"|"bass",
//               notes: [ { key: "c#/4"|null, sharp: bool, duration: "8"|"q"|"qd"|"h" }, ... ] }, ... ],
//   measureBreaks: [4, 4, 2, ...]  // 마디마다 음이 몇 개인지 — 모든 성부가 공유하는 한 벌
// }
//
// key가 null이면 쉼표(그 성부가 이 스텝엔 음이 없다는 뜻 — 온음계 밖 멜로디 음이라 화음을 못
// 정의한 경우 등). 예전엔 화음 없는 스텝을 그냥 건너뛰어서(compactMap) 성부마다 음 개수가
// 달랐고, 그걸 각자 4개씩 따로 마디로 쪼갰다 — 그래서 마디가 같은 자리에 있어도 실제로는 서로
// 다른 순간의 음이 세로로 겹쳐 그려지는 정렬 버그가 있었다. 지금은 쉼표로 빈 자리를 채워서
// 모든 성부의 음 배열 길이가 같고, `measureBreaks`(마디 구성) 하나를 전 성부가 그대로
// 공유한다 — 그래야 성부끼리 같은 순간의 음이 화면에서 정확히 세로로 맞는다.
//
// duration도 실제 길이(초, RhythmQuantizer가 중앙값 대비 상대적으로 분류)를 반영한다(59절).
//
// 재생 하이라이트(애플 뮤직 가사 하이라이트 방식으로 교체, 74절 이후) — 평소엔 모든 음표가
// 검정이고, 지금 소리 나는 스텝의 음표만 오렌지로 칠한다(성부 구분 색은 없앴다). 탭하면 그
// 지점부터 재생되도록, 각 스텝 폭만큼 투명한 히트 영역도 함께 그린다. renderScore가 새로 그릴
// 때마다 stepElements/stepX를 다시 채우고, setActiveStep(index)는 이 값들만 읽어서 이전
// 하이라이트를 되돌리고 새 하이라이트만 칠한다 — 매 50ms 재생 타이머 tick마다 renderScore
// 전체를 다시 부르면 낭비고, scoreWrapper 스크롤 위치도 원점으로 리셋돼버린다(35~38행에서
// 이미 겪은 문제와 같은 종류).
var BASE_NOTE_COLOR = '#1a1a1a';
var ACTIVE_NOTE_COLOR = '#FF9500';

var noteState = {
  svg: null,            // renderer가 그린 실제 <svg> 엘리먼트
  scale: 1,
  topY: 0,
  bottomY: 0,
  stepX: [],             // 스텝 인덱스 -> x좌표(원래 크기 단위, scale 곱하기 전) — rowIndex 0 기준
  stepElements: [],      // 스텝 인덱스 -> 그 순간 소리 나는 음표들의 SVG 엘리먼트 배열(쉼표 제외)
  activeIndex: null
};

// 명세서(v1.0) "부드러운 연속 스크롤" — 애플 뮤직 가사 뷰처럼 재생 중인 음표가 화면 중앙에
// 오도록 scoreWrapper를 자동으로 스크롤한다. 사용자가 손가락으로 직접 스와이프하는 동안은
// (탐색하고 싶어서 만진 것이므로) 자동 스크롤이 끼어들면 안 되니, touchstart~touchend 구간
// 동안은 건너뛴다 — 손을 떼면 다음 setActiveStep 호출(다음 음으로 넘어가는 시점) 때 자동으로
// 다시 따라붙는다.
var isUserTouching = false;
// 실기기 재생 테스트에서 "악보 넘어가면서 소리가 날 때 렉이 걸린다"는 제보 — 원인은 음표가
// 바뀔 때마다(빠른 8분음표면 초당 여러 번) `scrollTo({behavior:'smooth'})`를 매번 새로
// 걸어서, 브라우저 내장 스무스 스크롤 애니메이션이 끝나기도 전에 계속 새 애니메이션으로
// 갈아치워지는 것(애니메이션 재시작 자체가 비용이고, 재생 중 오디오 처리와 CPU를 다툰다 —
// 84절에서 겪은 "IPC/연산이 재생 중 CPU를 다툰다" 패턴과 같은 계열). 목표 스크롤 위치가
// 마지막으로 실제로 스크롤을 건 지점과 충분히(SCROLL_RETRIGGER_THRESHOLD픽셀 이상) 멀어졌을
// 때만 새로 스크롤을 걸어서, 화면에 이미 보이는 근처 음표로 넘어갈 땐 애니메이션을 다시
// 걸지 않는다 — 몇 음마다 한 번씩만 "훌쩍" 이동하지만, 그 편이 매 음마다 애니메이션을
// 재시작하는 것보다 훨씬 부드럽게 느껴진다.
var lastScrollTargetX = null;
var SCROLL_RETRIGGER_THRESHOLD = 40;

function initAutoScrollTouchTracking() {
  var wrapper = document.getElementById('scoreWrapper');
  if (!wrapper) return;
  wrapper.addEventListener('touchstart', function () { isUserTouching = true; }, { passive: true });
  wrapper.addEventListener('touchend', function () { isUserTouching = false; }, { passive: true });
  wrapper.addEventListener('touchcancel', function () { isUserTouching = false; }, { passive: true });
}

// 활성 스텝의 x좌표(원래 크기 단위)를 화면 중앙에 오도록 scoreWrapper를 스크롤한다.
// stepX[index]는 그 음표의 왼쪽 경계 근처 좌표라 정확한 중심은 아니지만, 음표 폭 자체가
// 작아서(악보 전체 폭 대비) 이 정도 근사로도 "중앙 근처"로 충분히 자연스럽게 보인다.
function scrollActiveStepIntoView(index) {
  if (isUserTouching) return;
  var wrapper = document.getElementById('scoreWrapper');
  if (!wrapper || index === null || index === undefined) return;
  var x = noteState.stepX[index];
  if (x === undefined) return;

  var pixelX = x * noteState.scale;
  if (lastScrollTargetX !== null && Math.abs(pixelX - lastScrollTargetX) < SCROLL_RETRIGGER_THRESHOLD) return;
  lastScrollTargetX = pixelX;

  var target = pixelX - wrapper.clientWidth / 2;
  var maxScroll = Math.max(0, wrapper.scrollWidth - wrapper.clientWidth);
  target = Math.max(0, Math.min(maxScroll, target));
  wrapper.scrollTo({ left: target, behavior: 'smooth' });
}

// el 자신과 그 자손 중 fill/stroke 속성을 가진 노드를 전부 찾아 색을 바꾼다. VexFlow가 그릴 때
// 색을 각 path에 직접 attribute로 굽기 때문에, 부모 그룹의 색만 바꿔서는 상속되지 않는다(DOM을
// 직접 확인해서 이렇게 결정 — docs/CONCEPTS.md 74절).
function recolor(el, color) {
  if (!el) return;
  if (el.hasAttribute('fill')) el.setAttribute('fill', color);
  if (el.hasAttribute('stroke')) el.setAttribute('stroke', color);
  var descendants = el.querySelectorAll('[fill], [stroke]');
  descendants.forEach(function (node) {
    if (node.hasAttribute('fill')) node.setAttribute('fill', color);
    if (node.hasAttribute('stroke')) node.setAttribute('stroke', color);
  });
}

// index가 가리키는 스텝의 음표(들)만 강조색으로 칠하고, 이전에 칠했던 스텝은 검정으로 되돌린다.
function setActiveStep(index) {
  if (noteState.activeIndex !== null && noteState.stepElements[noteState.activeIndex]) {
    noteState.stepElements[noteState.activeIndex].forEach(function (el) { recolor(el, BASE_NOTE_COLOR); });
  }
  noteState.activeIndex = (index === null || index === undefined) ? null : index;
  if (noteState.activeIndex === null) {
    // 149절 — 재생이 끝나면(Swift가 null을 보낸다) 악보를 처음으로 되감는다. 노래가 끝났는데
    // 마지막 마디에 머물러 있으면 다시 듣기 전에 매번 손으로 맨 앞까지 스크롤해야 한다.
    // 쉼표 구간에서는 null이 오지 않는다(ScoreTimeline.highlightIndex가 직전 음표를 유지한다) —
    // 안 그러면 노래 중간에 악보가 맨 앞으로 튕긴다.
    lastScrollTargetX = null;
    var wrapper = document.getElementById('scoreWrapper');
    if (wrapper) wrapper.scrollTo({ left: 0, behavior: 'smooth' });
    return;
  }
  scrollActiveStepIntoView(noteState.activeIndex);
  var elements = noteState.stepElements[noteState.activeIndex];
  if (!elements) return;
  elements.forEach(function (el) { recolor(el, ACTIVE_NOTE_COLOR); });
}

// 탭한 스텝의 음표를 즉시 살짝 눌렀다 돌아오는 느낌으로 깜빡여서, "눌렸다"는 걸 바로 알려준다.
// setActiveStep(재생이 실제로 그 지점에 도달했을 때 오렌지로 칠하는 것)과는 별개 — 이건 탭한
// 즉시(Swift 쪽 재생 준비가 아직 안 끝났어도) 반응이 와야 하는 순수 시각 피드백이라 색이 아니라
// 투명도를 잠깐 낮췄다 올리는 방식으로 구현했다(recolor의 fill/stroke 갱신과 안 부딪힘).
function flashTapFeedback(index) {
  var elements = noteState.stepElements[index];
  if (!elements) return;
  elements.forEach(function (el) {
    el.style.transition = 'opacity 0.08s ease-out';
    el.style.opacity = '0.3';
    setTimeout(function () {
      el.style.transition = 'opacity 0.18s ease-in';
      el.style.opacity = '1';
    }, 80);
  });
}

// 애플 뮤직 가사 탭과 같은 상호작용 — 음표 글자 자체가 아니라 "그 박자 전체 구간"(이웃 스텝과의
// 중간 지점까지)을 탭 영역으로 잡는다. 작은 음표head를 정확히 맞추기 어려운 터치 UX 문제를
// 피하기 위해서다.
function addTapRegions() {
  if (!noteState.svg) return;
  var xs = noteState.stepX;
  var n = xs.length;
  if (n === 0) return;

  for (var idx = 0; idx < n; idx++) {
    var leftBound = idx === 0 ? 0 : (xs[idx - 1] + xs[idx]) / 2;
    var rightBound = idx === n - 1 ? xs[idx] + (xs[idx] - leftBound) : (xs[idx] + xs[idx + 1]) / 2;

    var rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    rect.setAttribute('x', leftBound * noteState.scale);
    rect.setAttribute('y', noteState.topY * noteState.scale);
    rect.setAttribute('width', Math.max(0, (rightBound - leftBound) * noteState.scale));
    rect.setAttribute('height', (noteState.bottomY - noteState.topY) * noteState.scale);
    // fill: transparent로 뒀더니 실기기에서 흔적(세로선)이 남는 문제가 있었다 — "투명하지만
    // 클릭은 받는 영역"의 표준 SVG 관용구는 fill: none + pointer-events: all이라, 그쪽으로
    // 바꿔서 확실히 안 보이게 한다(75절 후속).
    rect.setAttribute('fill', 'none');
    rect.setAttribute('stroke', 'none');
    rect.setAttribute('pointer-events', 'all');

    (function (capturedIndex) {
      rect.addEventListener('click', function () {
        flashTapFeedback(capturedIndex);
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.harmonyUpNoteTap) {
          window.webkit.messageHandlers.harmonyUpNoteTap.postMessage(capturedIndex);
        }
      });
    })(idx);

    noteState.svg.appendChild(rect);
  }
}

function renderScore(data) {
  var container = document.getElementById('score');
  container.innerHTML = '';
  noteState = { svg: null, scale: 1, topY: 0, bottomY: 0, stepX: [], stepElements: [], activeIndex: null };
  lastScrollTargetX = null;

  var VF = Vex.Flow;
  var voices = (data.voices || []).filter(function (v) { return v.notes.length > 0; });
  var measureBreaks = data.measureBreaks || [];

  if (voices.length === 0 || measureBreaks.length === 0) {
    container.style.width = '1px';
    container.style.height = '1px';
    return;
  }

  // 새로 그릴 때마다 스크롤 위치를 원점으로 되돌린다 — 성부를 켜고 끄면(voices.length가
  // 바뀌면) 악보 전체 크기가 매번 달라지는데, 이전 스크롤 위치를 그대로 두면 새로 그려진
  // (더 작아지거나 커진) 악보에서 엉뚱한 부분만 보이는 "잘림" 현상이 생긴다(66절 이후 피드백:
  // "부분 보기 하려고 꺼버리면 악보랑 음이 잘리는 현상이 계속 발생").
  var wrapper = document.getElementById('scoreWrapper');
  if (wrapper) { wrapper.scrollLeft = 0; wrapper.scrollTop = 0; }

  // 실기기에서 "너무 작다"는 피드백을 받아, 전체를 SCALE배 확대해서 그린다 — 아래 모든 좌표
  // 계산은 그대로 "원래 크기" 단위로 하고, 마지막에 캔버스 크기와 컨텍스트만 SCALE배로
  // 키운다.
  var SCALE = 1.4;
  var firstMeasureExtraWidth = 55; // 음자리표+박자표 그릴 여유
  // 100 -> 130: "악보가 서로 너무 붙어있다" 피드백으로 성부 간 세로 간격을 넓힘.
  var staveRowHeight = 130;
  var leftPad = 4;
  var topPad = 20;
  // 쉼표뿐이거나 음이 거의 없는 마디도 너무 좁아지지 않게 하는 하한.
  var minMeasureWidth = 130;
  // 마디마다 실제로 필요한 너비에 더해주는 여유 — "간격 널널하게" 피드백 반영.
  var measurePadding = 50;

  // VexFlow 음표 코드 -> 박(4분음표=1박) 환산. 마디의 VF.Voice num_beats를 실제 박 합으로
  // 줘야(음표 개수가 아니라) 포매터가 8분음표/점4분음표를 제대로 배치한다.
  var DURATION_BEATS = { '8': 0.5, 'q': 1, 'qd': 1.5, 'h': 2 };
  // 쉼표는 음높이가 없지만 VexFlow는 그려질 위치(keys)가 필요하다 — 오선 가운데줄 관례.
  var REST_KEY = { treble: 'b/4', bass: 'd/3' };

  // 모든 성부가 같은 마디 구성(measureBreaks)을 공유하므로, 여기서 그 구성 그대로 잘라서
  // 전 성부에 동일하게 적용한다.
  function chunkByBreaks(notes, breaks) {
    var result = [];
    var index = 0;
    breaks.forEach(function (count) {
      result.push(notes.slice(index, index + count));
      index += count;
    });
    return result;
  }

  // 측정(1차)과 그리기(2차) 양쪽에서 똑같이 쓴다 — VexFlow의 StaveNote/Voice는 한 번
  // 포매팅에 쓰인 객체를 다른 컨텍스트에서 재사용하기 까다로워서, 매번 새로 만든다.
  function buildStaveNotes(measureNotes, clef) {
    return measureNotes.map(function (n) {
      var isRest = !n.key;
      var keys = isRest ? [REST_KEY[clef]] : [n.key];
      var duration = n.duration + (isRest ? 'r' : '');
      var note = new VF.StaveNote({ clef: clef, keys: keys, duration: duration });
      if (!isRest && n.sharp) { note.addModifier(new VF.Accidental('#'), 0); }
      return note;
    });
  }

  function measureBeats(measureNotes) {
    return measureNotes.reduce(function (sum, n) { return sum + (DURATION_BEATS[n.duration] || 1); }, 0);
  }

  var voiceMeasures = voices.map(function (v) { return chunkByBreaks(v.notes, measureBreaks); });
  var measureCount = measureBreaks.length;

  // 1차: 마디마다 실제로 필요한 너비를 계산한다 — 예전엔 마디 폭이 고정(190px)이라, 음이 적은
  // 마디는 억지로 늘어나 음표가 비정상적으로 길게 보이고("원래 음표가 저렇게 길게 표현되지
  // 않을텐데" 피드백의 원인), 음이 많은 마디는 반대로 촘촘해졌다. VexFlow의
  // preCalculateMinTotalWidth로 각 성부가 그 마디에 실제로 필요로 하는 최소 너비를 구하고,
  // 성부 중 가장 넓게 필요로 하는 값을 그 마디의 너비로 쓴다(모든 성부가 같은 마디 구성을
  // 공유해서 마디선이 세로로 맞아야 하니, 성부마다 다른 폭을 줄 수는 없다).
  var measureWidths = [];
  for (var m = 0; m < measureCount; m++) {
    var widest = 0;
    voices.forEach(function (voiceData, rowIndex) {
      var measureNotes = voiceMeasures[rowIndex][m] || [];
      if (measureNotes.length === 0) return;
      var notes = buildStaveNotes(measureNotes, voiceData.clef);
      var vfVoice = new VF.Voice({ num_beats: measureBeats(measureNotes), beat_value: 4 });
      vfVoice.setStrict(false);
      vfVoice.addTickables(notes);
      var needed = new VF.Formatter().preCalculateMinTotalWidth([vfVoice]);
      widest = Math.max(widest, needed);
    });
    measureWidths.push(Math.max(minMeasureWidth, widest + measurePadding));
  }

  var totalWidth = leftPad + firstMeasureExtraWidth + measureWidths.reduce(function (a, b) { return a + b; }, 0) + 30;
  var totalHeight = topPad + voices.length * staveRowHeight + 20;

  container.style.width = (totalWidth * SCALE) + 'px';
  container.style.height = (totalHeight * SCALE) + 'px';

  var renderer = new VF.Renderer(container, VF.Renderer.Backends.SVG);
  renderer.resize(totalWidth * SCALE, totalHeight * SCALE);
  var context = renderer.getContext();
  context.scale(SCALE, SCALE);

  // 2차: 실제로 그린다 — 이번엔 1차에서 계산한 마디별 너비(measureWidths)를 그대로 쓴다.
  voices.forEach(function (voiceData, rowIndex) {
    var y = topPad + rowIndex * staveRowHeight;
    var measures = voiceMeasures[rowIndex];
    var x = leftPad;
    // 모든 성부가 같은 measureBreaks를 공유해서, 같은 스텝 인덱스는 어느 성부에서 재도 같은
    // 순간을 가리킨다(위 buildPayload 쪽 주석과 동일한 전제) — 그래서 스텝 인덱스 카운터를
    // 성부마다 독립적으로 0부터 다시 세도 서로 어긋나지 않는다. x좌표(stepX)는 rowIndex 0
    // 기준만 기록해서 탭 히트 영역에 쓴다(어차피 같은 스텝은 어느 성부에서든 같은 x).
    var globalStepIndex = 0;

    for (var i = 0; i < measureCount; i++) {
      var isFirst = i === 0;
      var width = measureWidths[i] + (isFirst ? firstMeasureExtraWidth : 0);
      var stave = new VF.Stave(x, y, width);
      if (isFirst) {
        stave.addClef(voiceData.clef);
        stave.addTimeSignature('4/4');
      }
      stave.setContext(context).draw();

      var measureNotes = measures[i] || [];
      if (measureNotes.length > 0) {
        var staveNotes = buildStaveNotes(measureNotes, voiceData.clef);
        staveNotes.forEach(function (note) {
          note.setStyle({ fillStyle: BASE_NOTE_COLOR, strokeStyle: BASE_NOTE_COLOR });
        });

        var vfVoice = new VF.Voice({ num_beats: measureBeats(measureNotes), beat_value: 4 });
        vfVoice.setStrict(false);
        vfVoice.addTickables(staveNotes);
        var formatWidth = width - (isFirst ? firstMeasureExtraWidth + 20 : 20);
        new VF.Formatter().joinVoices([vfVoice]).format([vfVoice], formatWidth);
        vfVoice.draw(context, stave);

        // 8분음표가 연달아 나오면 빔(beam)으로 이어 그려서 실제 악보처럼 묶어 보여준다 —
        // 쉼표나 다른 길이의 음표를 만나면 자동으로 끊긴다(59절).
        var beams = VF.Beam.generateBeams(staveNotes, { beam_rests: false });
        beams.forEach(function (beam) { beam.setContext(context).draw(); });

        // draw() 이후에만 각 노트의 실제 SVG 엘리먼트를 얻을 수 있다(getSVGElement가
        // document.getElementById로 draw 시점에 만들어진 DOM 노드를 찾아오므로).
        staveNotes.forEach(function (note, noteIdx) {
          if (rowIndex === 0) {
            noteState.stepX[globalStepIndex] = note.getAbsoluteX();
          }
          var sourceNote = measureNotes[noteIdx];
          if (sourceNote.key) { // 쉼표는 하이라이트 대상에서 제외
            var el = note.getSVGElement();
            if (el) {
              if (!noteState.stepElements[globalStepIndex]) noteState.stepElements[globalStepIndex] = [];
              noteState.stepElements[globalStepIndex].push(el);
            }
          }
          globalStepIndex++;
        });
      } else {
        globalStepIndex += measureBreaks[i];
      }

      x += width;
    }
  });

  noteState.svg = context.svg || null;
  noteState.scale = SCALE;
  noteState.topY = topPad - 15;
  noteState.bottomY = topPad + voices.length * staveRowHeight - 20;

  addTapRegions();
}

window.renderScore = renderScore;
window.setActiveStep = setActiveStep;

// score.html이 body 끝에서 이 스크립트를 로드하므로 #scoreWrapper는 이미 DOM에 있다 —
// scoreWrapper 자체는 renderScore가 다시 그려도 재생성되지 않는 고정 컨테이너라 한 번만 걸면 된다.
initAutoScrollTouchTracking();
