import http from 'k6/http';
import { check, sleep } from 'k6';

const baseUrl = __ENV.BASE_URL || "http://127.0.0.1";
const targetHost = __ENV.TARGET_HOST || "app.platform.local";

export const options = {
  vus: 1,
  iterations: 1,

  thresholds: {
    checks: ["rate==1"],
    http_req_failed: ["rate==0"],
    http_req_duration: ["p(95)<1000"],
  },
};

export default function () {
  const response = http.get(`${baseUrl}/health`, {
    headers: {
      Host: targetHost,
    },
    tags: {
      test_type: "smoke",
    },
  });

  check(response, {
    "status is 200": (r) => r.status === 200,
    "response body is not empty": (r) => r.body !== null && r.body.length > 0,
  });

  sleep(1);
}
