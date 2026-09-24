// v1.7.0（§5）：PlaybackTimelineRecorder 语义回归锁。
//
// - begin 开新时间线并替换 _current（换集竞态下旧流迟到记录被 key
//   不匹配丢弃）；
// - 无键记录（recordOpen/recordFirstFrame/fail）只作用于当前时间线；
// - recordFirstBufferEnd 仅在首帧已出后生效（换集过渡期 buffering
//   翻转不提前盖章）；
// - P50/P90 统计只计成功样本。
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/player/playback_timeline.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PlaybackTimelineRecorder.instance.clear();
  });

  test('begin → record* → export 全链路记录', () {
    final recorder = PlaybackTimelineRecorder.instance;
    recorder.begin(label: '测试番剧 第 1 集', episodeUrl: 'https://s.com/e1');
    recorder.recordResolveStart('https://s.com/e1');
    recorder.recordWinner('https://s.com/e1', level: 'fast', host: 'cdn.x.com');
    recorder.recordOpen();
    recorder.recordFirstFrame();
    recorder.recordFirstBufferEnd();

    final t = recorder.records.single;
    expect(t.succeeded, isTrue);
    expect(t.winnerLevel, 'fast');
    expect(t.winnerHost, 'cdn.x.com');
    expect(t.tapToFirstFrame, isNotNull);
    expect(t.tFirstBufferEnd, isNotNull);
    // 导出文本包含关键分段。
    final text = recorder.exportAll();
    expect(text, contains('测试番剧 第 1 集'));
    expect(text, contains('fast@cdn.x.com'));
  });

  test('换集后旧流的键控记录被丢弃，无键记录落在新时间线', () {
    final recorder = PlaybackTimelineRecorder.instance;
    recorder.begin(label: '旧集', episodeUrl: 'https://s.com/e1');
    recorder.recordResolveStart('https://s.com/e1');
    // 换集：新时间线顶替。
    recorder.begin(label: '新集', episodeUrl: 'https://s.com/e2');
    // 旧流的迟到键控记录：key 不匹配 → 丢弃。
    recorder.recordWinner('https://s.com/e1', level: 'cache', host: 'old');
    // 新流正常推进。
    recorder.recordWinner('https://s.com/e2', level: 'webview', host: 'new');

    final current = recorder.records.first;
    expect(current.label, '新集');
    expect(current.winnerLevel, 'webview');
    expect(current.winnerHost, 'new');
  });

  test('recordFirstBufferEnd 在首帧前不生效', () {
    final recorder = PlaybackTimelineRecorder.instance;
    recorder.begin(label: '缓冲先于首帧', episodeUrl: 'https://s.com/e1');
    // 换集过渡期 buffering=false 翻转：首帧未出 → 不记录。
    recorder.recordFirstBufferEnd();
    expect(recorder.current!.tFirstBufferEnd, isNull);
    // 首帧到达后再翻转：记录。
    recorder.recordFirstFrame();
    recorder.recordFirstBufferEnd();
    expect(recorder.current!.tFirstBufferEnd, isNotNull);
  });

  test('fail 终止时间线；P50/P90 只计成功样本', () {
    final recorder = PlaybackTimelineRecorder.instance;
    recorder.begin(label: '失败集', episodeUrl: 'https://s.com/e1');
    recorder.fail('视频解析超时');
    expect(recorder.records.single.failureReason, '视频解析超时');
    expect(recorder.tapToFirstFrameStats().samples, 0);

    recorder.begin(label: '成功集', episodeUrl: 'https://s.com/e2');
    recorder.recordFirstFrame();
    expect(recorder.tapToFirstFrameStats().samples, 1);
  });

  test('环形缓冲：超过 50 条淘汰最旧', () {
    final recorder = PlaybackTimelineRecorder.instance;
    for (var i = 0; i < 60; i++) {
      recorder.begin(label: '第 $i 集', episodeUrl: 'https://s.com/e$i');
    }
    expect(recorder.records.length, 50);
    expect(recorder.records.first.label, '第 59 集');
    expect(recorder.records.last.label, '第 10 集');
  });

  test('每集只记一次（??= 幂等），换集后重新计', () {
    final recorder = PlaybackTimelineRecorder.instance;
    recorder.begin(label: '第 1 集', episodeUrl: 'https://s.com/e1');
    final t1 = recorder.current!;
    recorder.recordFirstFrame();
    // 同一集重复首帧事件（videoParams 多次到达）：不重置。
    recorder.recordFirstFrame();
    expect(t1.tFirstFrame, isNotNull);

    recorder.begin(label: '第 2 集', episodeUrl: 'https://s.com/e2');
    expect(recorder.current!.tFirstFrame, isNull);
    recorder.recordFirstFrame();
    expect(recorder.current!.tFirstFrame, isNotNull);
  });
}
