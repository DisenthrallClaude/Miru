import 'package:flutter_test/flutter_test.dart';
import 'package:miru/bean/dialog/update_dialog.dart';

void main() {
  group('stripMarkdown：GitHub Release 说明清洗', () {
    test('标题井号与加粗星号被清除', () {
      const input = '## 更新内容\n\n### 播放体验\n\n- **修复误报**：不再弹窗';
      final out = stripMarkdown(input);
      expect(out, isNot(contains('#')));
      expect(out, isNot(contains('**')));
      expect(out, contains('修复误报'));
      expect(out, contains('· '));
    });

    test('链接语法保留文字丢弃 URL', () {
      const input = '请到 [发布页](https://github.com/x/releases) 查看';
      final out = stripMarkdown(input);
      expect(out, contains('发布页'));
      expect(out, isNot(contains('https://')));
      expect(out, isNot(contains('](')));
    });

    test('行内代码与分隔线处理', () {
      const input = '使用 `flutter build` 构建\n\n---\n\n尾注';
      final out = stripMarkdown(input);
      expect(out, isNot(contains('`')));
      expect(out, contains('——'));
    });

    test('图片语法整体删除', () {
      const input = '前文\n![截图](https://img.example/1.png)\n后文';
      final out = stripMarkdown(input);
      expect(out, isNot(contains('![')));
      expect(out, contains('前文'));
      expect(out, contains('后文'));
    });

    test('三个以上连续空行压缩为两个', () {
      const input = 'a\n\n\n\n\nb';
      expect(stripMarkdown(input), 'a\n\nb');
    });

    test('空串与纯文本原样通过', () {
      expect(stripMarkdown(''), '');
      expect(stripMarkdown('普通文本'), '普通文本');
    });
  });
}
