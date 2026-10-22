import 'update_art.dart';

/// What the glasses show while their own app is stopped -- an upload, a
/// firmware update: the eye wired up (update_art.dart), and under it a line
/// of text and, if wanted, a progress bar.
///
/// It goes through the REPL, one write of about 240 bytes at a time. So the
/// art is sent once, into globals, by [load] -- a reset wipes them, [load]
/// again after one -- and then every [draw] is a single write.
///
/// Every frame is drawn whole anyway, so the current runs: sparks along the
/// cables (updateWires), one cell nearer the eye with every [draw] or
/// [tick].
class GlassesPicture {
  /// [run]: runs Lua on the glasses and waits for the token it prints --
  /// Repl.run.
  GlassesPicture(this.run);
  final Future<void> Function(String lua, String token) run;

  /// The longest write; the REPL takes about 240 bytes.
  static const maxWrite = 230;

  static const scale = 6; // 48x27 art -> 288x162
  static const screenWidth = 640;
  static const top = 16;
  static const textX = 120;
  static const barWidth = 400; // even: two pixels a byte
  static const barHeight = 12;

  /// A spark every this many cells along a cable: a head and its tail.
  static const sparkGap = 4;

  int _phase = 0;
  String _line = '';
  String? _second;
  double? _progress;

  static int get artX => (screenWidth - updateArt.first.length * scale) ~/ 2;
  static int get textY => top + updateArt.length * scale + 22;
  static int get barY => textY + 60;

  /// Sends the art and the drawing functions: D() the art, B(f) a bar
  /// filled to f, 0..1.
  Future<void> load() async {
    final colors = updateArtColors.entries
        .map((e) => e.key == '.' ? "['.']=${e.value}" : '${e.key}=${e.value}')
        .join(',');
    // the app turns the panel off while it has nothing to show, and stopped
    // it stays off: the picture would go into a dark screen (seen: nothing
    // on the glasses through a whole firmware install)
    await run(
      'frame.display.power_save(false) '
          "C={$colors} A={} P={} S=$scale X=$artX Y=$top print('p0')",
      'p0',
    );
    for (var i = 0; i < updateArt.length; i += 3) {
      final rows = [
        for (var j = i; j < i + 3 && j < updateArt.length; j++)
          "A[${j + 1}]='${updateArt[j]}'",
      ].join(' ');
      await run("$rows print('p$i')", 'p$i');
    }
    await run(
      'function D() for n,s in ipairs(A) do local t={} '
          'for c in s:gmatch(\'.\') do '
          't[#t+1]=string.rep(string.char(C[c]*17),S//2) end '
          'frame.display.bitmap(X,Y+(n-1)*S,#s*S,16,0,'
          "string.rep(table.concat(t),S)) end end print('pd')",
      'pd',
    );
    for (var i = 0; i < updateWires.length; i++) {
      await run(
        "P[${i + 1}]={${updateWires[i].join(',')}} print('pp$i')",
        'pp$i',
      );
    }
    // E(p): the sparks at phase p -- a SKYBLUE head (14 * 17), a SEABLUE
    // tail (13 * 17) behind it, toward the connector
    await run(
      'function E(p) for _,w in ipairs(P) do for i=0,#w//3-1 do '
          'local k,j=(i-p)%$sparkGap,i*3 if k<2 then local c=w[j+3]*S '
          'frame.display.bitmap(X+w[j+1]*S,Y+w[j+2]*S,c,16,0,'
          'string.char(k<1 and 238 or 221):rep(c*S//2)) '
          "end end end end print('pe')",
      'pe',
    );
    // filled LIGHTGREEN (11 * 17), the rest GREY (2 * 17)
    await run(
      'function B(f) local n=math.floor($barWidth*f/2) '
          'frame.display.bitmap($textX,$barY,$barWidth,16,0,string.rep('
          'string.rep(string.char(187),n)..'
          'string.rep(string.char(34),${barWidth ~/ 2}-n),$barHeight)) end '
          "print('pb')",
      'pb',
    );
  }

  /// The art, [line] under it, and a bar at [progress] (0..1) if given, or
  /// else [second], a line where the bar would be; the sparks one cell on.
  Future<void> draw(String line, {double? progress, String? second}) {
    _line = line;
    _second = second;
    _progress = progress;
    _phase = (_phase + 1) % sparkGap;
    final below = progress != null
        ? 'B(${progress.clamp(0.0, 1.0).toStringAsFixed(3)}) '
        : second != null
        ? "frame.display.text('${_text(second)}',$textX,$barY) "
        : '';
    return run(
      "D() E($_phase) frame.display.text('${_text(line)}',$textX,$textY) "
          "${below}frame.display.show() print('pw')",
      'pw',
    );
  }

  /// The same again, the sparks one cell on: for a long step, between its
  /// parts.
  Future<void> tick() => draw(_line, progress: _progress, second: _second);

  /// Leaves the picture up until the next reset: nothing else can draw.
  /// frame.update() puts its own 'Frame Update' on screen just before the
  /// glasses go to the bootloader, through these same two functions.
  Future<void> freeze() => run(
    'frame.display.text=function() end '
        "frame.display.show=function() end print('pf')",
    'pf',
  );

  /// ASCII the font has, without what would end the Lua string, and short
  /// enough to fit the screen and the write.
  static String _text(String s) {
    final t = s.replaceAll(RegExp(r"[^ -~]|['\\]"), '?');
    // about 20 px a character, from x = 120 to the edge at 640
    return t.length > 25 ? '${t.substring(0, 24)}~' : t;
  }
}
