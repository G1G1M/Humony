// HarmonyUp 전용 VexFlow 렌더링 로직. Swift(VexFlowScoreView)가 window.renderScore(data)를
// 직접 호출한다 — data는 이미 JS 객체 리터럴로 평가되는 JSON(문자열 아님)이라 파싱이 필요 없다.
//
// data 형식:
// {
//   voices: [ { clef: "treble"|"bass", color: "#RRGGBB",
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
function renderScore(data) {
  var container = document.getElementById('score');
  container.innerHTML = '';

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
          note.setStyle({ fillStyle: voiceData.color, strokeStyle: voiceData.color });
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
      }

      x += width;
    }
  });
}

window.renderScore = renderScore;
