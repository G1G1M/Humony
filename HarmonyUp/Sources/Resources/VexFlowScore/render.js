// HarmonyUp 전용 VexFlow 렌더링 로직. Swift(VexFlowScoreView)가 window.renderScore(data)를
// 직접 호출한다 — data는 이미 JS 객체 리터럴로 평가되는 JSON(문자열 아님)이라 파싱이 필요 없다.
//
// data 형식:
// { voices: [ { clef: "treble"|"bass", color: "#RRGGBB", notes: [ { key: "c#/4", sharp: bool }, ... ] }, ... ] }
//
// 이 앱은 박자/템포를 검출하지 않아서(초 단위 시작시각/길이만 있음), 모든 음을 4분음표로 두고
// 4개씩 4/4박자 한 마디로 묶어 순서대로 그린다 — "박자가 정확한 악보"는 아니지만 "음높이가
// 정확한 악보"는 된다(docs/CONCEPTS.md 57절).
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

  if (voices.length === 0) {
    container.style.width = '1px';
    container.style.height = '1px';
    return;
  }

  // 실기기에서 "너무 작다"는 피드백을 받아, 전체를 SCALE배 확대해서 그린다 — 아래 모든 좌표
  // 계산은 그대로 "원래 크기" 단위로 하고, 마지막에 캔버스 크기와 컨텍스트만 SCALE배로
  // 키운다(컨텍스트를 미리 확대해두면 그 이후 그리는 모든 것 — 오선/음표/음자리표 —이
  // 비례해서 커진다).
  var SCALE = 1.4;
  var measureWidth = 190; // 음표 사이 간격 — 라벨을 없앤 만큼, 그래도 여유 있게 넓혔다.
  var firstMeasureExtraWidth = 55; // 음자리표+박자표 그릴 여유
  var staveRowHeight = 100;
  var leftPad = 4;
  var topPad = 20;

  function chunk(notes, size) {
    var result = [];
    for (var i = 0; i < notes.length; i += size) {
      result.push(notes.slice(i, i + size));
    }
    return result;
  }

  var voiceMeasures = voices.map(function (v) { return chunk(v.notes, 4); });
  var measureCount = 0;
  voiceMeasures.forEach(function (m) { measureCount = Math.max(measureCount, m.length); });

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

    // 성부 하나가 다른 성부보다 마디 수가 적을 수 있다(예: 반음계 밖 음이라 화음이 없는 구간) —
    // 그래도 오선 자체는 measureCount만큼 이어져야 줄이 뚝 끊기지 않는다.
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
          var note = new VF.StaveNote({ clef: voiceData.clef, keys: [n.key], duration: 'q' });
          if (n.sharp) {
            note.addModifier(new VF.Accidental('#'), 0);
          }
          note.setStyle({ fillStyle: voiceData.color, strokeStyle: voiceData.color });
          return note;
        });

        var vfVoice = new VF.Voice({ num_beats: staveNotes.length, beat_value: 4 });
        vfVoice.setStrict(false);
        vfVoice.addTickables(staveNotes);
        var formatWidth = width - (isFirst ? firstMeasureExtraWidth + 20 : 20);
        new VF.Formatter().joinVoices([vfVoice]).format([vfVoice], formatWidth);
        vfVoice.draw(context, stave);
      }

      x += width;
    }
  });
}

window.renderScore = renderScore;
