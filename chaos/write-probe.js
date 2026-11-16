// k6 write probe: a steady 20 writes/s against the orders API during a chaos experiment.
// Every acknowledged write (HTTP 201) is logged with its unique item name, so afterwards we can prove that
// no acknowledged write was lost (RPO) and measure the longest gap in successful writes (user-visible outage).
import http from 'k6/http';

export const options = {
  scenarios: {
    writes: {
      executor: 'constant-arrival-rate',
      rate: 20,
      timeUnit: '1s',
      duration: __ENV.DURATION || '150s',
      preAllocatedVUs: 40,
      maxVUs: 400,
    },
  },
  summaryTrendStats: ['p(50)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const item = `chaos-${__ENV.RUN}-${__VU}-${__ITER}`;
  const started = Date.now();
  const res = http.post('http://orders.orders.svc/orders', JSON.stringify({ item: item, quantity: 1 }), {
    headers: { 'Content-Type': 'application/json' },
    timeout: '30s',
  });
  const done = Date.now();
  if (res.status === 201) {
    console.log(`ACK ${item} ${started} ${done}`);
  } else {
    console.log(`ERR ${res.status} ${started} ${done}`);
  }
}
