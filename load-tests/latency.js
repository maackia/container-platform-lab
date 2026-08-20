import http from "k6/http";
import { check, sleep } from "k6";

const baseUrl = __ENV.BASE_URL || "http://127.0.0.1";
const targetHost = __ENV.TARGET_HOST || "app.platform.local";

export const options = {
  scenarios: {
    latency: {
      // 가상 사용자 수를 단계적으로 변경한다.
      executor: "ramping-vus",
      startVUs: 0,

      stages: [
        // 15초 동안 사용자를 3명까지 늘린다.
        { duration: "15s", target: 3 },

        // p95 경고가 FIRING 상태가 될 수 있도록
        // 느린 요청을 2분 30초 동안 유지한다.
        { duration: "2m30s", target: 3 },

        // 마지막 15초 동안 사용자를 0명으로 줄인다.
        { duration: "15s", target: 0 },
      ],

      gracefulRampDown: "10s",
    },
  },

  thresholds: {
    // HTTP 응답 자체는 정상적으로 200이어야 한다.
    checks: ["rate>0.99"],
    http_req_failed: ["rate<0.01"],

    // 이 테스트는 p95 지연을 의도적으로 발생시키는 테스트다.
    // p95가 1초를 넘으면 지연 상황 재현에 성공한 것으로 본다.
    "http_req_duration{test_type:latency}": ["p(95)>1000"],
  },
};

export default function () {
  const response = http.get(`${baseUrl}/slow`, {
    headers: {
      Host: targetHost,
    },

    tags: {
      test_type: "latency",
    },
  });

  check(response, {
    // 느린 요청이어도 HTTP 처리는 정상 완료되어야 한다.
    "status is 200": (res) => res.status === 200,
    "response body is not empty": (res) =>
      res.body !== null && res.body.length > 0,
  });

  sleep(1);
}
