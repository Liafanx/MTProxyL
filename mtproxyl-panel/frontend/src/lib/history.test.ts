import { counterSteps, gaugeValues, niceScaleTicks, rateValues, windowDelta } from './history';
import type { HistorySeries } from '@/lib/api';

function assertDeepEqual(actual: unknown, expected: unknown) {
  const actualJson = JSON.stringify(actual);
  const expectedJson = JSON.stringify(expected);
  if (actualJson !== expectedJson) {
    throw new Error(`Expected ${expectedJson}, got ${actualJson}`);
  }
}

const series = (points: Array<[number, number]>): HistorySeries => ({
  metric: 'connections',
  range: '30m',
  state: 'ready',
  requested_from_epoch_secs: 0,
  retention_secs: 7200,
  points: points.map(([ts, v]) => ({ ts, v })),
});

assertDeepEqual(
  counterSteps([{ ts: 0, v: 0 }, { ts: 5, v: 10 }, { ts: 10, v: 8 }, { ts: 400, v: 20 }, { ts: 405, v: 25 }]),
  [{ from: 0, to: 5, delta: 10, seconds: 5 }, { from: 400, to: 405, delta: 5, seconds: 5 }],
);

assertDeepEqual(rateValues(series([[0, 0], [5, 10], [10, 30], [400, 40], [405, 50], [410, 55]])), [2, 1]);
assertDeepEqual(rateValues(series([[0, 0], [5, 10], [400, 5]])), []);
assertDeepEqual(rateValues(series([[0, 0]])), []);

assertDeepEqual(windowDelta(series([[0, 0], [5, 10], [10, 30], [15, 31]]), 10), 21);
assertDeepEqual(windowDelta(series([[0, 0]]), 10), null);

assertDeepEqual(gaugeValues(series([[0, 3], [5, 4]])), [3, 4]);

assertDeepEqual(niceScaleTicks(0), [1, 0]);
assertDeepEqual(niceScaleTicks(7), [8, 6, 4, 2, 0]);
assertDeepEqual(niceScaleTicks(123), [150, 100, 50, 0]);
assertDeepEqual(niceScaleTicks(1000), [1000, 800, 600, 400, 200, 0]);
