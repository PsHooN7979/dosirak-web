// dosirak_core.dart
// 순수 Dart 파일 (Flutter 의존성 없음 → 단위 테스트 쉬움). Dart 3 이상.

class Member {
  final String id;
  final String name;
  final String kakaoNick; // 단톡방에 표시되는 이름 (파서가 이걸로 매칭)
  final bool active; // 인원 변동: 삭제 대신 비활성 처리 → 과거 정산 보존
  const Member({
    required this.id,
    required this.name,
    required this.kakaoNick,
    this.active = true,
  });
}

/// 가격 이력: 가격이 바뀌어도 과거 정산이 틀어지지 않음
class PriceEntry {
  final DateTime from; // 이 날짜부터 적용
  final int price;
  const PriceEntry(this.from, this.price);
}

class MealLog {
  final DateTime date; // 날짜만 사용
  final String memberId;
  final int count; // 하루 다수 도시락 가능, 0이면 취소
  const MealLog(this.date, this.memberId, this.count);

  /// 같은 날 같은 사람이 다시 입력하면 덮어쓰기 (Firestore 문서 ID로 사용)
  String get docId => '${_ymd(date)}_$memberId';
}

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 키워드 파서
/// 예) "#도시락" → 1개, "#도시락 2" → 2개, "#도시락 0" → 취소
class MealParser {
  static final _re = RegExp(r'#도시락\s*(\d{1,2})?');

  static MealLog? parse({
    required String sender,
    required String text,
    required DateTime receivedAt,
    required List<Member> members,
  }) {
    final m = _re.firstMatch(text);
    if (m == null) return null;

    final count = int.tryParse(m.group(1) ?? '') ?? 1;
    final member = members
        .where((x) => x.active && x.kakaoNick == sender.trim())
        .firstOrNull;
    if (member == null) return null; // 등록 안 된 닉네임은 무시

    final day = DateTime(receivedAt.year, receivedAt.month, receivedAt.day);
    return MealLog(day, member.id, count);
  }
}

/// 특정 날짜에 적용되는 가격
int priceOn(List<PriceEntry> history, DateTime day) {
  if (history.isEmpty) return 0;
  final sorted = [...history]..sort((a, b) => a.from.compareTo(b.from));
  var price = sorted.first.price; // 첫 가격 시작일 이전 날짜는 첫 가격으로 계산
  for (final p in sorted) {
    if (!p.from.isAfter(day)) price = p.price;
  }
  return price;
}

/// 월 정산: memberId → 청구 금액
Map<String, int> monthlyTotals({
  required int year,
  required int month,
  required List<MealLog> logs,
  required List<PriceEntry> prices,
}) {
  final totals = <String, int>{};
  for (final l in logs) {
    if (l.date.year != year || l.date.month != month) continue;
    final amount = l.count * priceOn(prices, l.date);
    totals.update(l.memberId, (v) => v + amount, ifAbsent: () => amount);
  }
  return totals;
}

// ─────────────────────────────────────────────
// 카톡 알림 수신 뼈대 (pubspec: notification_listener_service)
//
// NotificationListenerService.notificationsStream.listen((e) {
//   if (e.packageName != 'com.kakao.talk') return;
//   // ⚠️ 단톡방 알림의 title/content 구성은 카톡 버전마다 다릅니다.
//   //    먼저 print(e.title); print(e.content); 로 실제 값을 확인한 뒤
//   //    (방 이름, 보낸 사람, 메시지)를 분리하세요.
//   final log = MealParser.parse(
//     sender: sender, text: message,
//     receivedAt: DateTime.now(), members: members,
//   );
//   if (log != null) { /* Firestore: meals/{log.docId} 에 set() */ }
// });
// ─────────────────────────────────────────────