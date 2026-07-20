const http = require("http");
const { Client } = require("pg");
const client = require("prom-client");

client.collectDefaultMetrics();

const httpRequestsTotal = new client.Counter({
  name: "app_http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["method", "route", "status_code"],
});

const dbQueriesTotal = new client.Counter({
  name: "app_db_queries_total",
  help: "Total number of database queries",
  labelNames: ["operation", "status"],
});

const dbConfig = {
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
};

async function queryDb() {
  const client = new Client(dbConfig);
  await client.connect();

  // 기존 테이블 생성 처리를 db/init/01-create-visits.sql 에서 처리

  await client.query("INSERT INTO visits DEFAULT VALUES");
  dbQueriesTotal.inc({ operation: "insert_visit", status: "success" });

  const result = await client.query("SELECT COUNT(*) AS count FROM visits");
  dbQueriesTotal.inc({ operation: "count_visits", status: "success" });

  await client.end();

  return result.rows[0].count;
}

const server = http.createServer(async (req, res) => {
  if (req.url === "/health") {
    httpRequestsTotal.inc({
      method: req.method,
      route: "/health",
      status_code: "200",
    });

    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("OK\n");
    return;
  }

  if (req.url === "/metrics") {
    httpRequestsTotal.inc({
      method: req.method,
      route: "/metrics",
      status_code: "200",
    });

    res.writeHead(200, { "Content-Type": client.register.contentType });
    res.end(await client.register.metrics());
    return;
  }

  try {
    const count = await queryDb();

    httpRequestsTotal.inc({
      method: req.method,
      route: "/",
      status_code: "200",
    });

    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end(`Hello from Node app container\nVisit count: ${count}\n`);
  } catch (err) {
    console.error(err);

    dbQueriesTotal.inc({ operation: "request", status: "error" });

    httpRequestsTotal.inc({
      method: req.method,
      route: "/",
      status_code: "500",
    });

    res.writeHead(500, { "Content-Type": "text/plain" });
    res.end(`DB error: ${err.message}\n`);
  }
});

server.listen(3000, "0.0.0.0", () => {
  console.log("App listening on port 3000");
});
