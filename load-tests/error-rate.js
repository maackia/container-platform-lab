import http from "k6/http";
import { check, sleep } from "k6";

// 실행할 때 환경변수로 전달하며, 없으면 아래 기본값을 사용한다.
const BASE_URL = (__ENV.BASE_URL || "http://127.0.0.1").replace(/\/$/, "");
const TARGET_HOST = __ENV.TARGET_HOST || "app.platform.local";

// 이번 테스트에서 HTTP 500은 의도한 응답이다.
// 따라서 k6의 http_req_failed에는 실패로 기록하지 않는다.
const expectedErrorResponse = http.expectedStatuses(500);

export const options = {
  scenarios: {
    error_rate: {
      executor: "ramping-vus",
      startVUs: 0,

      stages: [
        // 30초 동안 사용자를 2명까지 증가시킨다.
        { duration: "30s", target: 2 },

        // 2분 동안 2명의 사용자가 계속 요청한다.
        { duration: "2m", target: 2 },

        // 30초 동안 사용자를 0명으로 줄인다.
        { duration: "30s", target: 0 },
      ],

      gracefulRampDown: "10s",
    },
  },

  thresholds: {
    // check() 조건의 99% 이상이 성공해야 한다.
    checks: ["rate>0.99"],

    // 의도한 500 응답이므로 k6 관점의 실패율은 0이어야 한다.
    "http_req_failed{test_type:error_rate}": ["rate==0"],

    // /error 응답 자체는 1초 이내에 처리되는지 확인한다.
    "http_req_duration{test_type:error_rate}": ["p(95)<1000"],
  },
};

export default function () {
  const response = http.get(`${BASE_URL}/error`, {
    headers: {
      Host: TARGET_HOST,
    },

    tags: {
      test_type: "error_rate",
    },

    // 이 요청에 한해서 500을 예상된 정상 응답으로 분류한다.
    responseCallback: expectedErrorResponse,
  });

  check(response, {
    "status is 500": (res) => res.status === 500,
    "response body is not empty": (res) => res.body.length > 0,
  });

  sleep(1);
}
