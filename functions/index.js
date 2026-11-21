// functions/index.js  (Firebase Cloud Functions v2)
// MacroDroid가 보낸 카톡 알림 -> 방 이름 / 보낸 사람 / 내용 분석 -> meals 저장
//
// 배포: firebase deploy --only functions

const {onRequest} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret} = require("firebase-functions/params");
const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();
const WEBHOOK_TOKEN = defineSecret("WEBHOOK_TOKEN");

// 반영할 단톡방 이름 (알림에 보이는 이름 그대로 입력).
// 비워두면("") 방을 구분하지 않고 모두 처리합니다.
const ROOM_NAME = "New 도시락🍱";

// "#도시락" -> 1개, "#도시락 2" -> 1개(하루 1개 고정), "#도시락 0" -> 취소
const KEYWORD = /#도시락\s*(\d{1,2})?/;

/**
 * 알림 전체 텍스트(여러 줄)에서 보낸 사람과 내용을 찾는다.
 * 줄 순서에 상관없이 동작한다.
 *  - 키워드(#도시락)가 있는 줄 = 내용
 *  - 다른 줄 중 멤버의 카톡 닉네임과 같은 줄 = 보낸 사람
 *  - 내용 줄이 "보낸사람 : 내용" 형태여도 인식
 * @param {string} raw 알림 전체 텍스트
 * @param {Array<{id: string, kakaoNick: string}>} members 활성 인원
 * @return {Object} {member, message, lines} (키워드 없으면 null)
 */
function parseNotification(raw, members) {
  const lines = raw.split("\n").map((s) => s.trim()).filter((s) => s);
  const msgIdx = lines.findIndex((l) => KEYWORD.test(l));
  if (msgIdx < 0) return null;

  let message = lines[msgIdx];
  const others = lines.filter((_, i) => i !== msgIdx);

  let member = members.find((m) => others.includes(m.kakaoNick));
  if (!member) {
    const m = message.match(/^(.+?)\s*:\s*([\s\S]+)$/);
    if (m) {
      member = members.find((x) => x.kakaoNick === m[1].trim());
      if (member) message = m[2];
    }
  }
  return {member, message, lines};
}

// ───────── 가격 이력에서 특정 날짜 단가 계산 ─────────
function priceOn(prices, dateStr) {
  if (prices.length === 0) return 0;
  let price = prices[0].price;
  for (const p of prices) {
    if (p.from <= dateStr) price = p.price;
  }
  return price;
}

function won(n) {
  return n.toLocaleString("ko-KR") + "원";
}

// ───────── 매월 1일 오전 9시 (KST) 정산 알림 ─────────
exports.monthlySettlement = onSchedule(
    {schedule: "0 0 1 * *", timeZone: "Asia/Seoul", region: "asia-northeast3"},
    async () => {
      const now = new Date(Date.now() + 9 * 3600 * 1000); // KST
      const year = now.getMonth() === 0 ? now.getFullYear() - 1 : now.getFullYear();
      const month = now.getMonth() === 0 ? 12 : now.getMonth();
      const pad = (n) => String(n).padStart(2, "0");
      const startDate = `${year}-${pad(month)}-01`;
      const endDate = month === 12
        ? `${year + 1}-01-01`
        : `${year}-${pad(month + 1)}-01`;

      const [membersSnap, mealsSnap, pricesSnap, tokensSnap] = await Promise.all([
        db.collection("members").where("active", "==", true).get(),
        db.collection("meals").where("date", ">=", startDate).where("date", "<", endDate).get(),
        db.collection("prices").get(),
        db.collection("device_tokens").get(),
      ]);

      const members = membersSnap.docs.reduce((acc, d) => {
        acc[d.id] = d.data().name;
        return acc;
      }, {});

      const prices = pricesSnap.docs
          .map((d) => ({from: d.data().from, price: d.data().price}))
          .sort((a, b) => a.from.localeCompare(b.from));

      // 멤버별 총액·일수 계산
      const totals = {};
      const eatDays = {};
      for (const doc of mealsSnap.docs) {
        const {date, memberId, count} = doc.data();
        if ((count || 0) <= 0) continue;
        const price = priceOn(prices, date);
        totals[memberId] = (totals[memberId] || 0) + count * price;
        eatDays[memberId] = (eatDays[memberId] || 0) + 1;
      }

      const messaging = admin.messaging();
      const staleTokens = [];

      for (const tokenDoc of tokensSnap.docs) {
        const {fcmToken, memberId} = tokenDoc.data();
        if (!fcmToken || !memberId || !members[memberId]) continue;

        const name = members[memberId];
        const total = totals[memberId] || 0;
        const days = eatDays[memberId] || 0;

        try {
          await messaging.send({
            token: fcmToken,
            notification: {
              title: `🍱 ${month}월 도시락 정산`,
              body: `${name}님 ${days}일 먹음 → ${won(total)}`,
            },
            android: {notification: {channelId: "dosirak_settlement"}},
          });
        } catch (e) {
          if (e.code === "messaging/registration-token-not-registered") {
            staleTokens.push(tokenDoc.ref);
          }
        }
      }

      // 만료된 토큰 정리
      await Promise.all(staleTokens.map((ref) => ref.delete()));
    },
);

exports.kakaoWebhook = onRequest(
    {region: "asia-northeast3", secrets: [WEBHOOK_TOKEN]},
    async (req, res) => {
      if (req.method !== "POST") return res.status(405).send("POST only");
      if (req.query.token !== WEBHOOK_TOKEN.value()) {
        return res.status(401).send("unauthorized");
      }

      const raw = req.rawBody.toString("utf8");

      const snap = await db.collection("members")
          .where("active", "==", true).get();
      const members = snap.docs.map((d) => ({
        id: d.id,
        kakaoNick: d.data().kakaoNick || d.data().name,
      }));

      const p = parseNotification(raw, members);
      let result;
      if (!p) {
        result = "no keyword";
      } else if (ROOM_NAME && !p.lines.some((l) => l.includes(ROOM_NAME))) {
        result = "other room";
      } else if (!p.member) {
        result = "unknown sender";
      } else {
        const m = p.message.match(KEYWORD);
        const count = m && m[1] === "0" ? 0 : 1;
        // 한국 시간 기준 날짜
        const kst = new Date(Date.now() + 9 * 3600 * 1000);
        const date = kst.toISOString().slice(0, 10);

        // 같은 날 같은 사람은 같은 문서 -> 중복 알림이 와도 덮어쓰기
        await db.collection("meals").doc(`${date}_${p.member.id}`).set({
          date,
          memberId: p.member.id,
          count,
          source: "kakao",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        result = `ok ${p.member.kakaoNick} ${count}`;
      }

      // 확인용 기록 (잘 동작하면 이 블록을 지워도 됩니다)
      await db.collection("rawNotifications").add({
        raw,
        result,
        at: admin.firestore.FieldValue.serverTimestamp(),
      });

      return res.send(result);
    },
);
