// 선착순 대기열(오픈런) 부하 테스트. 가상 고객 USERS명이 RAMP_S초 안에 한꺼번에 줄을 서고,
// 대기 화면처럼 2.5초마다 내 순번을 묻는다. 입장권을 받으면 THINK_MIN_S~THINK_MAX_S초 뒤 주문하고(ABANDON_RATE만큼은 포기),
// 품절·줄에서 빠짐이 오면 끝낸다.
//
// 클러스터 안(k8s Job)에서 order-service를 바로 부른다. gateway를 거치지 않으므로 Cognito 로그인이 없고,
// gateway가 붙이는 X-User-Id·X-User-Role을 직접 붙인다. X-User-Id는 실제 고객이 아닌 lt-<RUN_ID>-<번호>다.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://order-service:8080';
const STORE_ID = __ENV.STORE_ID;
const PRODUCT_ID = __ENV.PRODUCT_ID;
const STORE_NAME = __ENV.STORE_NAME || '부하테스트';
const USERS = parseInt(__ENV.USERS || '3000', 10);
const RAMP_S = parseFloat(__ENV.RAMP_S || '10');          // 이 시간 안에 모두 줄을 선다 (오픈 직후 몰림)
const POLL_S = parseFloat(__ENV.POLL_S || '2.5');         // 화면과 같은 주기 (frontend POLL_MS.firstComeQueue)
const THINK_MIN_S = parseFloat(__ENV.THINK_MIN_S || '5');
const THINK_MAX_S = parseFloat(__ENV.THINK_MAX_S || '60');
const ABANDON_RATE = parseFloat(__ENV.ABANDON_RATE || '0.1'); // 입장권을 받고도 주문하지 않는 비율 (5분 뒤 다음 사람 입장)
const MAX_WAIT_S = parseFloat(__ENV.MAX_WAIT_S || '900');  // 한 사람이 최대로 기다리는 시간
const RUN_ID = __ENV.RUN_ID || 'run';                     // 다시 돌릴 때 바꾼다 (1인 1개가 하루 기준이라 같은 ID는 다시 못 산다)

if (!STORE_ID || !PRODUCT_ID) {
  throw new Error('STORE_ID, PRODUCT_ID 환경 변수가 필요하다');
}

export const options = {
  scenarios: {
    openrun: {
      executor: 'per-vu-iterations',
      vus: USERS,
      iterations: 1,
      maxDuration: `${Math.ceil(RAMP_S + MAX_WAIT_S + THINK_MAX_S + 120)}s`,
      gracefulStop: '30s',
    },
  },
  thresholds: {
    'http_req_duration{name:queue_join}': ['p(95)<1000'],
    'http_req_duration{name:queue_me}': ['p(95)<500'],
    queue_errors: ['count<30'],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

const admitted = new Counter('queue_admitted');
const ordered = new Counter('queue_ordered');
const orderFailed = new Counter('queue_order_failed');
const abandoned = new Counter('queue_abandoned');
const soldOut = new Counter('queue_sold_out');
const dropped = new Counter('queue_not_in_queue');
const timedOut = new Counter('queue_gave_up_waiting');
const errors = new Counter('queue_errors');
const waitSeconds = new Trend('queue_wait_seconds');      // 줄 선 뒤 입장·품절까지 걸린 시간
const firstPosition = new Trend('queue_first_position');  // 처음 받은 순번

export default function () {
  const userId = `lt-${RUN_ID}-${__VU}`.slice(0, 36);
  const headers = { 'X-User-Id': userId, 'X-User-Role': 'CUSTOMER' };
  const q = `${BASE}/orders/queue/${PRODUCT_ID}`;
  const qs = `storeId=${STORE_ID}`;

  sleep(Math.random() * RAMP_S);
  let res = http.post(`${q}?${qs}`, null, { headers, tags: { name: 'queue_join' } });
  const start = Date.now();
  let body = parse(res);
  if (body && body.position) firstPosition.add(body.position);

  while (true) {
    if (!body) {
      errors.add(1);
      if ((Date.now() - start) / 1000 > MAX_WAIT_S) return timedOut.add(1);
      sleep(POLL_S); // 화면처럼 일시 오류는 다시 묻는다
      res = http.get(`${q}/me?${qs}`, { headers, tags: { name: 'queue_me' } });
      body = parse(res);
      continue;
    }
    switch (body.status) {
      case 'WAITING':
        if ((Date.now() - start) / 1000 > MAX_WAIT_S) return timedOut.add(1);
        sleep(POLL_S);
        res = http.get(`${q}/me?${qs}`, { headers, tags: { name: 'queue_me' } });
        body = parse(res);
        continue;
      case 'ADMITTED':
        admitted.add(1);
        waitSeconds.add((Date.now() - start) / 1000);
        return order(headers);
      case 'SOLD_OUT':
        soldOut.add(1);
        waitSeconds.add((Date.now() - start) / 1000);
        return;
      default: // NOT_IN_QUEUE
        dropped.add(1);
        return;
    }
  }
}

function order(headers) {
  if (Math.random() < ABANDON_RATE) {
    abandoned.add(1); // 주문 화면에서 나간 사람. 입장권은 5분 뒤 사라지고 다음 사람이 들어온다
    return;
  }
  sleep(THINK_MIN_S + Math.random() * (THINK_MAX_S - THINK_MIN_S));
  const res = http.post(
    `${BASE}/orders`,
    JSON.stringify({ storeId: Number(STORE_ID), storeName: STORE_NAME, productId: Number(PRODUCT_ID), quantity: 1 }),
    {
      headers: Object.assign({ 'Content-Type': 'application/json', 'Idempotency-Key': uuidv4() }, headers),
      tags: { name: 'order_create' },
    },
  );
  if (check(res, { 'order 2xx': (r) => r.status >= 200 && r.status < 300 })) ordered.add(1);
  else orderFailed.add(1);
}

// 주문 API가 Idempotency-Key로 UUID만 받는다. 파드에서 외부 jslib을 받지 않으려고 직접 만든다
function uuidv4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

function parse(res) {
  if (res.status !== 200) return null;
  try {
    return res.json();
  } catch (e) {
    return null;
  }
}
