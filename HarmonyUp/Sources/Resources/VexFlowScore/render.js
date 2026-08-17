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
// duration도 실제 길이(초, RhythmQuantizer가 중앙값 대비 상대적으로 분류)를 반영한다 — 예전엔
// 전부 4분음표로만 그려서 "인위적으로 보인다"는 피드백을 받았다(docs/CONCEPTS.md 59절). 정확한
// 박자 표기는 여전히 불가능하지만(이 앱은 템포를 검출하지 않음), 최소한 길고 짧음은 음표
// 모양(과 8분음표 빔 묶음)으로 보여준다 — 이게 "박자가 정확한 악보"는 아니어도 "리듬감이
// 있는 악보"는 되게 하는 절충안이다.
//
// v1(1차 시도)엔 음표마다 음이름 라벨(Annotation)을 붙였는데, 실기기에서 "너무 촘촘해서
// 겹친다"는 피드백을 받았다 — 라벨끼리 부딪히는 게 그 원인 중 하나였다. 이제는 진짜 오선
// 위치 자체가 정확한 음높이를 나타내므로(색깔 막대 방식과 달리 위치를 "짐작"할 필요가 없음)
// 라벨 없이 음표만 크고 단순하게 그린다 — 실제 악보가 원래 그렇듯, 위치가 곧 정보다.
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

  // 실기기에서 "너무 작다"는 피드백을 받아, 전체를 SCALE배 확대해서 그린다 — 아래 모든 좌표
  // 계산은 그대로 "원래 크기" 단위로 하고, 마지막에 캔버스 크기와 컨텍스트만 SCALE배로
  // 키운다(컨텍스트를 미리 확대해두면 그 이후 그리는 모든 것 — 오선/음표/음자리표 —이
  // 비례해서 커진다).
  var SCALE = 1.4;
  var measureWidth = 190;
  var firstMeasureExtraWidth = 55; // 음자리표+박자표 그릴 여유
  var staveRowHeight = 100;
  var leftPad = 4;
  var topPad = 20;

  // VexFlow 음표 코드 -> 박(4분음표=1박) 환산. 마디의 VF.Voice num_beats를 실제 박 합으로
  // 줘야(음표 개수가 아니라) 포매터가 8분음표/점4분음표를 제대로 배치한다.
  var DURATION_BEATS = { '8': 0.5, 'q': 1, 'qd': 1.5, 'h': 2 };
  // 쉼표는 음높이가 없지만 VexFlow는 그려질 위치(keys)가 필요하다 — 오선 가운데줄 관례.
  var REST_KEY = { treble: 'b/4', bass: 'd/3' };

  // 모든 성부가 같은 마디 구성(measureBreaks)을 공유하므로, 여기서 그 구성 그대로 잘라서
  // 전 성부에 동일하게 적용한다 — 성부마다 따로 4개씩 자르던 예전 방식은 화음이 빠진(쉼표)
  // 스텝이 있을 때 성부끼리 마디가 어긋나는 원인이었다.
  function chunkByBreaks(notes, breaks) {
    var result = [];
    var index = 0;
    breaks.forEach(function (count) {
      result.push(notes.slice(index, index + count));
      index += count;
    });
    return result;
  }

  var voiceMeasures = voices.map(function (v) { return chunkByBreaks(v.notes, measureBreaks); });
  var measureCount = measureBreaks.length;

  var totalWidth = leftPad + firstMeasureExtraWidth + measureCount * measureWidth + 30;
  var totalHeight = topPad + voices.length * staveRowHeight + 20;

  container.style.width = (totalWidth * SCALE) + 'px';
  container.style.height = (totalHeight * SCALE) + 'px';

  var renderer = new VF.Renderer(container, VF.Renderer.Backends.SVG);
  renderer.resize(totalWidth * SCALE, totalHeight * SCALE);
  var context = renderer.getContext();
  context.scale(SCALE, SCALE);

  voices.forEach(function (voiceData, rowIndex) {
    var y = topPad + rowIndex * staveRowHeight;
    var measures = voiceMeasures[rowIndex];
    var x = leftPad;

    for (var i = 0; i < measureCount; i++) {
      var isFirst = i === 0;
      var width = isFirst ? measureWidth + firstMeasureExtraWidth : measureWidth;
      var stave = new VF.Stave(x, y, width);
      if (isFirst) {
        stave.addClef(voiceData.clef);
        stave.addTimeSignature('4/4');
      }
      stave.setContext(context).draw();

      var measureNotes = measures[i] || [];
      if (measureNotes.length > 0) {
        var staveNotes = measureNotes.map(function (n) {
          var isRest = !n.key;
          var keys = isRest ? [REST_KEY[voiceData.clef]] : [n.key];
          var duration = n.duration + (isRest ? 'r' : '');
          var note = new VF.StaveNote({ clef: voiceData.clef, keys: keys, duration: duration });
          if (!isRest && n.sharp) {
            note.addModifier(new VF.Accidental('#'), 0);
          }
          note.setStyle({ fillStyle: voiceData.color, strokeStyle: voiceData.color });
          return note;
        });

        var totalBeats = measureNotes.reduce(function (sum, n) {
          return sum + (DURATION_BEATS[n.duration] || 1);
        }, 0);
        var vfVoice = new VF.Voice({ num_beats: totalBeats, beat_value: 4 });
        vfVoice.setStrict(false);
        vfVoice.addTickables(staveNotes);
        var formatWidth = width - (isFirst ? firstMeasureExtraWidth + 20 : 20);
        new VF.Formatter().joinVoices([vfVoice]).format([vfVoice], formatWidth);
        vfVoice.draw(context, stave);

        // 8분음표가 연달아 나오면 빔(beam)으로 이어 그려서 실제 악보처럼 묶어 보여준다 —
        // 쉼표나 다른 길이의 음표를 만나면 자동으로 끊긴다(레퍼런스 악보의 이어진 음표 묶음과
        // 같은 관례, docs/CONCEPTS.md 59절).
        var beams = VF.Beam.generateBeams(staveNotes, { beam_rests: false });
        beams.forEach(function (beam) { beam.setContext(context).draw(); });
      }

      x += width;
    }
  });
}

window.renderScore = renderScore;
