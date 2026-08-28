// 记录进入 tag 时 list 所在位置
class BBCodeTag {
  int? bold;
  int? italic;
  int? underline;
  int? strikeThrough;
  int? masked;
  int? quoted;
  int? code;
  int? size;
  int? color;
  int? link;
  int? img;

  void clear() {
    bold = null;
    italic = null;
    underline = null;
    strikeThrough = null;
    masked = null;
    quoted = null;
    code = null;
    size = null;
    color = null;
    link = null;
    img = null;
  }
}

class BBCodeText {
  String text;

  bool bold = false;
  bool italic = false;
  bool underline = false;
  bool strikeThrough = false;
  bool masked = false;
  bool quoted = false;
  bool code = false;

  int size = 14;
  String? color;
  String? link;

  BBCodeText({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikeThrough = false,
    this.masked = false,
    this.quoted = false,
    this.code = false,
    this.size = 14,
    this.color,
    this.link,
  });
}

class BBCodeBgm {
  int id;

  BBCodeBgm({required this.id});

  /// bgm 系表情图（(bgmN) 语法）的 CDN 地址。
  ///
  /// 分段规则：11/23 是动图（bgm/{id}.gif）；其余 1-23 为
  /// bgm/{id}.png；24-32 映射 tv/0{id-23}.gif（一位数补零）；
  /// 33 及以上映射 tv/{id-23}.gif。
  ///
  /// 历史版本用连续 if 且末行无条件覆盖，导致 id≤23 全部请求
  /// tv/负数.gif 必 404（渲染成「.」），此处改为互斥分支（F7）。
  static String smileUrl(int id) {
    if (id == 11 || id == 23) {
      return 'https://bangumi.tv/img/smiles/bgm/$id.gif';
    }
    if (id < 24) {
      return 'https://bangumi.tv/img/smiles/bgm/$id.png';
    }
    if (id < 33) {
      return 'https://bangumi.tv/img/smiles/tv/0${id - 23}.gif';
    }
    return 'https://bangumi.tv/img/smiles/tv/${id - 23}.gif';
  }
}

class BBCodeMusume {
  int id;

  BBCodeMusume({required this.id});
}

class BBCodeSticker {
  int id;

  BBCodeSticker({required this.id});
}

class BBCodeImg {
  String imageUrl;

  BBCodeImg({required this.imageUrl});
}

BBCodeTag bbCodeTag = BBCodeTag();
