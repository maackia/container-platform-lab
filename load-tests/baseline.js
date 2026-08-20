// k6가 제공하는 HTTP 요청 모듈을 가져온다.
// Node.js의 axios나 fetch 대신 k6/http를 사용한다.
import http from "k6/http";

// check: 응답이 기대한 조건을 만족하는지 검사한다.
// sleep: 가상 사용자의 행동 사이에 대기 시간을 넣는다.
import { check, sleep } from "k6";

// 실행할 때 BASE_URL 환경변수가 있으면 그 값을 사용한다.
// 없으면 기본값으로 Ubuntu의 로컬 주소를 사용한다.
const baseUrl = __ENV.BASE_URL || "http://127.0.0.1";

// TARGET_HOST 환경변수가 있으면 그 값을 사용한다.
// 없으면 Traefik Ingress에 등록한 app.platform.local을 사용한다.
const targetHost = __ENV.TARGET_HOST || "app.platform.local";

// k6의 테스트 실행 방법과 합격 기준을 정의한다.
// export하면 k6가 이 설정을 읽어서 테스트 실행에 사용한다.
export const options = {
  // 실행할 부하 시나리오들을 정의한다.
  scenarios: {
    // 시나리오 이름이다.
    // k6 결과에서 baseline이라는 이름으로 구분된다.
    baseline: {
      // 가상 사용자 수를 시간에 따라 점진적으로 변경한다.
      executor: "ramping-vus",

      // 테스트 시작 시 가상 사용자 수는 0명이다.
      startVUs: 0,

      // 시간에 따른 가상 사용자 수의 변화를 정의한다.
      stages: [
        // 30초 동안 가상 사용자를 0명에서 5명까지 늘린다.
        { duration: "30s", target: 5 },

        // 이후 1분 동안 가상 사용자 5명을 유지한다.
        { duration: "1m", target: 5 },

        // 마지막 30초 동안 가상 사용자를 5명에서 0명으로 줄인다.
        { duration: "30s", target: 0 },
      ],

      // 사용자를 줄이는 시점에 실행 중인 요청을 바로 중단하지 않고
      // 최대 10초 동안 정상적으로 마무리할 시간을 준다.
      gracefulRampDown: "10s",
    },
  },

  // 테스트 전체의 합격 및 실패 기준을 정의한다.
  thresholds: {
    // check 검사 중 99%를 초과하는 비율이 성공해야 한다.
    checks: ["rate>0.99"],

    // HTTP 요청 실패율은 1%보다 낮아야 한다.
    http_req_failed: ["rate<0.01"],

    // 전체 HTTP 요청 중 95%가 500ms 안에 완료되어야 한다.
    http_req_duration: ["p(95)<500"],
  },
};

// 각 가상 사용자가 반복해서 실행하는 함수다.
//
// VU가 5명이면 이 함수를 동시에 실행하는 흐름이
// 최대 5개 존재한다고 이해하면 된다.
export default function () {
  // 애플리케이션의 루트 경로로 GET 요청을 보낸다.
  const response = http.get(`${baseUrl}/`, {
    // 요청에 HTTP Host 헤더를 추가한다.
    //
    // 실제 연결 주소는 127.0.0.1이지만,
    // Traefik은 이 Host 값을 보고 platform-lab 앱으로 전달한다.
    headers: {
      Host: targetHost,
    },

    // 이 요청에서 수집되는 k6 메트릭에 사용자 정의 태그를 추가한다.
    //
    // 나중에 baseline 요청 결과만 필터링할 때 사용할 수 있다.
    tags: {
      test_type: "baseline",
    },
  });

  // 방금 받은 응답이 기대한 조건을 만족하는지 검사한다.
  check(response, {
    // HTTP 응답 코드가 200이면 성공한다.
    "status is 200": (res) => res.status === 200,

    // 응답 본문이 null이 아니고 한 글자 이상 존재하면 성공한다.
    "response body is not empty": (res) =>
      res.body !== null && res.body.length > 0,
  });

  // 현재 가상 사용자가 다음 요청을 보내기 전에 1초간 기다린다.
  //
  // 실제 사용자가 페이지를 보고 다음 행동을 하기까지 걸리는
  // 시간인 think time을 단순하게 재현한 것이다.
  sleep(1);
}
