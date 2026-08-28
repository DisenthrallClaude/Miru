/// This class asks for DateTime to get a string to indicate seasonal anime
class AnimeSeason {
  late DateTime _date;
  final _seasons = ['冬季', '春季', '夏季', '秋季'];

  AnimeSeason(DateTime date) {
    _date = date;
  }

  List<int> _getYearAndSeason(DateTime dt) {
    int year = dt.year;
    int month = dt.month;

    int season;
    if ((month == 1) || (month == 2) || (month == 3)) {
      season = 0;
    } else if ((month == 4) || (month == 5) || (month == 6)) {
      season = 1;
    } else if ((month == 7) || (month == 8) || (month == 9)) {
      season = 2;
    } else {
      season = 3;
    }

    return [year, season];
  }

  // Convert the DateTime to a List containing two strings (the start of the season -1 and the end of the season -1 ) eg: 2024-09-23 -> ['2024-06-01', '2024-09-01']
  // why -1? because the air date is the launch date of the anime, it is usually a few days before the start of the season
  List<String> toSeasonStartAndEnd() {
    var yas = _getYearAndSeason(_date);
    int year = yas[0];
    int season = yas[1];

    var end = DateTime(year, (season + 1) * 3, 1);

    int startMonth = season * 3;
    if (startMonth == 0) {
      startMonth = 12;
      year--;
    }

    var start = DateTime(year, startMonth, 1);
    // 输出必须是 yyyy-MM-dd 纯日期（F12）：该串作为 air_date 过滤值
    // 下发后按字符串字典序比较，带 " 00:00:00.000" 的
    // DateTime.toString() 会让 start 当日条目被排除、end 当日条目被误含。
    return [_formatDate(start), _formatDate(end)];
  }

  String _formatDate(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  @override
  String toString() {
    var yas = _getYearAndSeason(_date);

    return '${yas[0]}年${_seasons[yas[1]]}新番';
  }
}

String getSeasonStringByMonth(int month) {
  if (month <= 3) return '冬';
  if (month <= 6) return '春';
  if (month <= 9) return '夏';
  return '秋';
}

bool isSameSeason(DateTime d1, DateTime d2) {
  // 与季度选项卡同一套日历季度划分（冬=1-3 月、春=4-6、夏=7-9、
  // 秋=10-12，见 timeline_page.generateDateTime）。原先的
  // 「月份差绝对值 ≤2」会把 2 月与 4 月（冬/春）误判同季（F20）。
  return d1.year == d2.year &&
      ((d1.month - 1) ~/ 3) == ((d2.month - 1) ~/ 3);
}
