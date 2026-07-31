import { QUOTA_ENDPOINT } from './useQuotaEndpoint';

if (QUOTA_ENDPOINT !== '/v1/stats/users/quota') {
  throw new Error(`Expected /v1/stats/users/quota, got ${QUOTA_ENDPOINT}`);
}
