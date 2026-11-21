// lib/main.dart  — 도시락웹 (Flutter Web + Firestore)
// 같은 lib/ 폴더에 dosirak_core.dart, firebase_options.dart 가 있어야 합니다.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dosirak_core.dart';
import 'firebase_options.dart';

final db = FirebaseFirestore.instance;

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String won(int n) =>
    '${n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',')}원';

// ───────── Firestore 스트림 ─────────
// members: {name, kakaoNick, active, order}
// prices (문서ID=적용시작일): {from: 'yyyy-MM-dd', price}
// meals  (문서ID=날짜_memberId): {date, memberId, count}  ← count>0 이면 먹는 날

/// 설정에서 정한 순서(order)대로 정렬된 인원 목록
/// order 가 없는 기존 인원은 맨 뒤에 이름순으로 표시됩니다.
Stream<List<Member>> membersStream() => db.collection('members').snapshots().map((s) {
      int orderOf(QueryDocumentSnapshot<Map<String, dynamic>> d) =>
          (d.data()['order'] as num?)?.toInt() ?? 1000000;
      final docs = [...s.docs]..sort((a, b) {
          final c = orderOf(a).compareTo(orderOf(b));
          if (c != 0) return c;
          return ('${a.data()['name'] ?? ''}').compareTo('${b.data()['name'] ?? ''}');
        });
      return docs.map((d) {
        final m = d.data();
        return Member(
          id: d.id,
          name: m['name'] ?? '',
          kakaoNick: m['kakaoNick'] ?? '',
          active: m['active'] ?? true,
        );
      }).toList();
    });

Stream<List<PriceEntry>> pricesStream() =>
    db.collection('prices').snapshots().map((s) => s.docs.map((d) {
          final m = d.data();
          return PriceEntry(DateTime.parse(m['from']), (m['price'] as num).toInt());
        }).toList());

Stream<int> minMembersStream() =>
    db.collection('settings').doc('general').snapshots().map(
      (s) => (s.data()?['minMembers'] as num?)?.toInt() ?? 1,
    );

/// 도시락은 하루 1개 고정: 먹으면 1, 안 먹으면 0
Future<void> setEating(String date, String memberId, bool eating) =>
    db.collection('meals').doc('${date}_$memberId').set({
      'date': date,
      'memberId': memberId,
      'count': eating ? 1 : 0,
      'source': 'web',
      'updatedAt': FieldValue.serverTimestamp(),
    });

Future<List<String>?> askFields(
    BuildContext context, String title, List<String> labels) {
  final ctrls = [for (final _ in labels) TextEditingController()];
  return showDialog<List<String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < labels.length; i++)
          TextField(
            controller: ctrls[i],
            decoration: InputDecoration(labelText: labels[i]),
          ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, [for (final c in ctrls) c.text.trim()]),
          child: const Text('확인'),
        ),
      ],
    ),
  );
}

// ───────── 앱 ─────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const DosirakWeb());
}

class DosirakWeb extends StatelessWidget {
  const DosirakWeb({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '도시락웹',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.orange,
          useMaterial3: true,
          appBarTheme: const AppBarTheme(centerTitle: true),
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    _initFCM();
  }

  Future<void> _initFCM() async {
    if (kIsWeb) return; // 웹은 별도 VAPID 설정 필요
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus != AuthorizationStatus.authorized) return;

    final token = await messaging.getToken();
    if (token != null) await _saveToken(token);
    messaging.onTokenRefresh.listen(_saveToken);
  }

  Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    final memberId = prefs.getString('selected_member_id');
    if (memberId == null) return;
    await db.collection('device_tokens').doc(token).set({
      'fcmToken': token,
      'memberId': memberId,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('🍱 도시락'),
            bottom: const TabBar(
              tabs: [Tab(text: '오늘'), Tab(text: '설정')],
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: const TabBarView(
                children: [TodayTab(), SettingsTab()],
              ),
            ),
          ),
        ),
      );
}

// ───────── 오늘 탭: 달력 + 월 정산 ─────────
class TodayTab extends StatefulWidget {
  const TodayTab({super.key});
  @override
  State<TodayTab> createState() => _TodayTabState();
}

class _TodayTabState extends State<TodayTab> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);

  void _move(int d) => setState(() => month = DateTime(month.year, month.month + d));

  void _goToday() => setState(
      () => month = DateTime(DateTime.now().year, DateTime.now().month));

  @override
  Widget build(BuildContext context) {
    final start = ymd(month);
    final end = ymd(DateTime(month.year, month.month + 1));
    final now = DateTime.now();
    final isCurrentMonth = month.year == now.year && month.month == now.month;

    return StreamBuilder<int>(
      stream: minMembersStream(),
      builder: (context, minMs) {
        final minMembers = minMs.data ?? 1;
        return StreamBuilder<List<Member>>(
          stream: membersStream(), // 설정에서 정한 순서대로 들어옴
          builder: (context, ms) => StreamBuilder<List<PriceEntry>>(
            stream: pricesStream(),
            builder: (context, ps) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db
                  .collection('meals')
                  .where('date', isGreaterThanOrEqualTo: start)
                  .where('date', isLessThan: end)
                  .snapshots(),
              builder: (context, snap) {
                final members = ms.data ?? <Member>[];
                final orderOf = {for (var i = 0; i < members.length; i++) members[i].id: i};
                final nameOf = {for (final m in members) m.id: m.name};
                final docs =
                    snap.data?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[];

                // 날짜 → 먹는 사람 id 목록, 정산용 로그 (하루 1개 고정)
                final idsByDate = <String, List<String>>{};
                final logs = <MealLog>[];
                for (final d in docs) {
                  if ((d['count'] as num) <= 0) continue;
                  final id = d['memberId'] as String;
                  if (!nameOf.containsKey(id)) continue;
                  final date = d['date'] as String;
                  idsByDate.putIfAbsent(date, () => []).add(id);
                  logs.add(MealLog(DateTime.parse(date), id, 1));
                }
                for (final l in idsByDate.values) {
                  l.sort((a, b) => orderOf[a]!.compareTo(orderOf[b]!));
                }
                final namesByDate = {
                  for (final e in idsByDate.entries) e.key: [for (final id in e.value) nameOf[id]!]
                };
                final todayNames = namesByDate[ymd(now)] ?? <String>[];

                // 최소 인원 미달 날짜 제외 후 정산
                final filteredLogs = logs
                    .where((l) => (idsByDate[ymd(l.date)]?.length ?? 0) >= minMembers)
                    .toList();
                final totals = monthlyTotals(
                  year: month.year,
                  month: month.month,
                  logs: filteredLogs,
                  prices: ps.data ?? <PriceEntry>[],
                );
                final eatDays = <String, int>{};
                for (final l in filteredLogs) {
                  eatDays.update(l.memberId, (v) => v + 1, ifAbsent: () => 1);
                }
                final sum = totals.values.fold<int>(0, (a, b) => a + b);
                final settleRows =
                    members.where((m) => m.active || totals.containsKey(m.id)).toList();

                return Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _move(-1)),
                    Text('${month.year}년 ${month.month}월',
                        style: Theme.of(context).textTheme.titleLarge),
                    IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _move(1)),
                    if (!isCurrentMonth)
                      TextButton(onPressed: _goToday, child: const Text('오늘')),
                  ]),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Column(children: [
                        if (isCurrentMonth)
                          Card(
                            child: ListTile(
                              leading: const Icon(Icons.lunch_dining),
                              title: Text('오늘 도시락 ${todayNames.length}명'),
                              subtitle: Text(todayNames.isEmpty
                                  ? '아직 신청한 사람이 없어요'
                                  : todayNames.join(', ')),
                            ),
                          ),
                        const SizedBox(height: 4),
                        _grid(context, namesByDate, members, minMembers),
                        const SizedBox(height: 16),
                        // ── 월 정산 (달력 아래) ──
                        Card(
                          child: Column(children: [
                            ListTile(
                              title: Text('${month.month}월 정산',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(fontWeight: FontWeight.bold)),
                              subtitle: minMembers > 1
                                  ? Text('$minMembers명 미만인 날은 제외됨',
                                      style: Theme.of(context).textTheme.bodySmall)
                                  : null,
                            ),
                            const Divider(height: 1),
                            for (final m in settleRows)
                              ListTile(
                                title: Text(m.name),
                                subtitle: Text('${eatDays[m.id] ?? 0}일'),
                                trailing: Text(won(totals[m.id] ?? 0)),
                              ),
                            const Divider(height: 1),
                            ListTile(
                              title: const Text('합계'),
                              trailing: Text(won(sum),
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 24),
                      ]),
                    ),
                  ),
                ]);
              },
            ),
          ),
        );
      },
    );
  }

  Widget _grid(BuildContext context, Map<String, List<String>> namesByDate,
      List<Member> members, int minMembers) {
    final first = DateTime(month.year, month.month, 1);
    final offset = first.weekday % 7; // 일요일 시작
    final days = DateTime(month.year, month.month + 1, 0).day;
    final rows = ((offset + days) / 7).ceil();
    final todayStr = ymd(DateTime.now());
    const weekdays = ['일', '월', '화', '수', '목', '금', '토'];

    return Column(children: [
      Row(children: [
        for (final w in weekdays)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  w,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: w == '일' ? Colors.red : (w == '토' ? Colors.blue : null),
                  ),
                ),
              ),
            ),
          ),
      ]),
      for (var r = 0; r < rows; r++)
        Row(children: [
          for (var c = 0; c < 7; c++)
            Expanded(
              child: _cell(context, r * 7 + c - offset + 1, days, namesByDate, members,
                  todayStr, minMembers),
            ),
        ]),
    ]);
  }

  Widget _cell(BuildContext context, int day, int days,
      Map<String, List<String>> namesByDate, List<Member> members, String todayStr,
      int minMembers) {
    if (day < 1 || day > days) return const SizedBox(height: 92);
    final cs = Theme.of(context).colorScheme;
    final dateStr = ymd(DateTime(month.year, month.month, day));
    final names = namesByDate[dateStr] ?? const <String>[];
    final isToday = dateStr == todayStr;
    // 사람은 있지만 최소 인원 미달인 날 → 회색
    final belowMin = names.isNotEmpty && names.length < minMembers;
    final shown = names.take(3).toList();

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _editDay(context, dateStr, members),
      child: Container(
        height: 92,
        margin: const EdgeInsets.all(1.5),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: isToday
              ? cs.primaryContainer
              : belowMin
                  ? cs.surfaceContainerHighest
                  : cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '$day',
            style: TextStyle(
              fontSize: 12,
              fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
              color: belowMin ? cs.onSurface.withValues(alpha: 0.4) : null,
            ),
          ),
          for (final n in shown)
            Text(
              n,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: belowMin
                    ? cs.onSurface.withValues(alpha: 0.4)
                    : cs.primary,
              ),
            ),
          if (names.length > 3)
            Text('+${names.length - 3}',
                style: TextStyle(
                    fontSize: 10,
                    color: belowMin ? cs.onSurface.withValues(alpha: 0.4) : null)),
        ]),
      ),
    );
  }

  /// 날짜를 누르면 그날 먹는 사람을 체크/해제
  void _editDay(BuildContext context, String dateStr, List<Member> members) {
    final active = members.where((m) => m.active).toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: db.collection('meals').where('date', isEqualTo: dateStr).snapshots(),
        builder: (ctx, snap) {
          final docs =
              snap.data?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
          final on = {
            for (final d in docs)
              if ((d['count'] as num) > 0) d['memberId'] as String
          };
          return SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(dateStr, style: Theme.of(ctx).textTheme.titleMedium),
              ),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final m in active)
                    CheckboxListTile(
                      title: Text(m.name),
                      value: on.contains(m.id),
                      onChanged: (v) => setEating(dateStr, m.id, v == true),
                    ),
                ]),
              ),
            ]),
          );
        },
      ),
    );
  }
}

// ───────── 설정 (가격 / 인원·순서) ─────────
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});
  @override
  Widget build(BuildContext context) => ListView(children: const [
        _NotifSection(),
        Divider(),
        _MinMembersSection(),
        Divider(),
        _PriceSection(),
        Divider(),
        _MemberSection(),
      ]);
}

class _MinMembersSection extends StatelessWidget {
  const _MinMembersSection();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: minMembersStream(),
      builder: (context, snap) {
        final minMembers = snap.data ?? 1;
        return ListTile(
          leading: const Icon(Icons.group),
          title: const Text('최소 주문 인원'),
          subtitle: Text(
            minMembers <= 1
                ? '설정 없음 — 1명이어도 집계됩니다'
                : '$minMembers명 미만인 날은 집계에서 제외되고 달력에서 회색으로 표시됩니다',
            maxLines: 2,
          ),
          isThreeLine: minMembers > 1,
          trailing: FilledButton(
            onPressed: () async {
              final v = await askFields(context, '최소 주문 인원 설정', ['인원 수 (1 이상)']);
              final n = int.tryParse(v?.first ?? '');
              if (n == null || n < 1) return;
              await db
                  .collection('settings')
                  .doc('general')
                  .set({'minMembers': n}, SetOptions(merge: true));
            },
            child: const Text('변경'),
          ),
        );
      },
    );
  }
}

class _PriceSection extends StatelessWidget {
  const _PriceSection();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<PriceEntry>>(
      stream: pricesStream(),
      builder: (context, snap) {
        final prices = [...(snap.data ?? <PriceEntry>[])]
          ..sort((a, b) => b.from.compareTo(a.from));
        final current = priceOn(prices, DateTime.now());
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            title: const Text('도시락 가격'),
            subtitle: Text(prices.isEmpty ? '아직 설정 안 됨' : '현재 ${won(current)}'),
            trailing: FilledButton(
              onPressed: () async {
                final v = await askFields(context, '가격 변경 (오늘부터 적용)', ['가격(원)']);
                final p = int.tryParse(v?.first ?? '');
                if (p == null) return;
                final today = ymd(DateTime.now());
                await db.collection('prices').doc(today).set({'from': today, 'price': p});
              },
              child: const Text('변경'),
            ),
          ),
          for (final p in prices)
            ListTile(dense: true, title: Text('${ymd(p.from)}부터  ${won(p.price)}')),
        ]);
      },
    );
  }
}

// ───────── 알림 설정 ─────────
class _NotifSection extends StatefulWidget {
  const _NotifSection();
  @override
  State<_NotifSection> createState() => _NotifSectionState();
}

class _NotifSectionState extends State<_NotifSection> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance()
        .then((p) => setState(() => _selectedId = p.getString('selected_member_id')));
  }

  Future<void> _select(Member member) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_member_id', member.id);
    setState(() => _selectedId = member.id);

    if (!kIsWeb) {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await db.collection('device_tokens').doc(token).set({
          'fcmToken': token,
          'memberId': member.id,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${member.name}으로 알림 설정됨')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return const ListTile(
        title: Text('알림 설정'),
        subtitle: Text('푸시 알림은 모바일 앱에서만 지원됩니다'),
        leading: Icon(Icons.notifications_off_outlined),
      );
    }
    return StreamBuilder<List<Member>>(
      stream: membersStream(),
      builder: (context, snap) {
        final members = (snap.data ?? []).where((m) => m.active).toList();
        final selected = members.where((m) => m.id == _selectedId).firstOrNull;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('알림 받을 내 이름'),
            subtitle: Text(
              selected == null ? '선택 안 됨 — 선택해야 매월 1일 정산 알림을 받습니다' : '${selected.name} 으로 설정됨',
            ),
            isThreeLine: selected == null,
          ),
          for (final m in members)
            RadioListTile<String>(
              title: Text(m.name),
              value: m.id,
              groupValue: _selectedId,
              onChanged: (_) => _select(m),
            ),
        ]);
      },
    );
  }
}

class _MemberSection extends StatelessWidget {
  const _MemberSection();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Member>>(
      stream: membersStream(),
      builder: (context, snap) {
        final members = snap.data ?? <Member>[];
        return Column(children: [
          ListTile(
            title: const Text('인원'),
            subtitle: const Text('왼쪽 ≡ 아이콘을 끌어서 순서를 바꿔요 (달력·정산에 같은 순서로 표시)\n스위치를 끄면 비활성 처리돼요 (과거 정산은 유지)'),
            isThreeLine: true,
            trailing: FilledButton(
              onPressed: () async {
                final v = await askFields(context, '인원 추가', ['이름', '카톡 닉네임']);
                if (v == null || v[0].isEmpty) return;
                await db.collection('members').add({
                  'name': v[0],
                  'kakaoNick': v[1].isEmpty ? v[0] : v[1],
                  'active': true,
                  'order': members.length, // 맨 뒤에 추가
                });
              },
              child: const Text('추가'),
            ),
          ),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorder: (oldIndex, newIndex) async {
              if (newIndex > oldIndex) newIndex -= 1;
              final list = [...members];
              list.insert(newIndex, list.removeAt(oldIndex));
              final batch = db.batch();
              for (var i = 0; i < list.length; i++) {
                batch.update(db.collection('members').doc(list[i].id), {'order': i});
              }
              await batch.commit();
            },
            children: [
              for (var i = 0; i < members.length; i++)
                ListTile(
                  key: ValueKey(members[i].id),
                  leading: ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_handle),
                  ),
                  title: Text(members[i].name),
                  subtitle: Text('카톡: ${members[i].kakaoNick}'),
                  trailing: Switch(
                    value: members[i].active,
                    onChanged: (v) =>
                        db.collection('members').doc(members[i].id).update({'active': v}),
                  ),
                ),
            ],
          ),
        ]);
      },
    );
  }
}