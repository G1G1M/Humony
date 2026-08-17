// HarmonyUp 전용 VexFlow 렌더링 로직. Swift(VexFlowScoreView)가 window.renderScore(data)를
// 직접 호출한다 — data는 이미 JS 객체 리터럴로 평가되는 JSON(문자열 아님)이라 파싱이 필요 없다.
//
// data 형식:
// { voices: [ { clef: "treble"|"bass", color: "#RRGGBB", notes: [ { key: "c#/4", sharp: bool, label: "C#4" }, ... ] }, ... ] }
//
// 이 앱은 박자/템포를 검출하지 않아서(초 단위 시작시각/길이만 있음), 모든 음을 4분음표로 두고
// 4개씩 4/4박자 한 마디로 묶어 순서대로 그린다 — "박자가 정확한 악보"는 아니지만 "음높이가
// 정확한 악보"는 된다(docs/CONCEPTS.md 57절).
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

  var measureWidth = 150;
  var firstMeasureExtraWidth = 50; // 음자리표+박자표 그릴 여유
  var staveRowHeight = 90;
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

  container.style.width = totalWidth + 'px';
  container.style.height = totalHeight + 'px';

  var renderer = new VF.Renderer(container, VF.Renderer.Backends.SVG);
  renderer.resize(totalWidth, totalHeight);
  var context = renderer.getContext();

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
          var annotation = new VF.Annotation(n.label)
            .setFont('Arial', 8)
            .setVerticalJustification(VF.Annotation.VerticalJustify.BOTTOM);
          annotation.setStyle({ fillStyle: voiceData.color, strokeStyle: voiceData.color });
          note.addModifier(annotation, 0);
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
