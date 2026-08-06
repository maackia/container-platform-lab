const http = require("http");
const { Client } = require("pg");
const promClient = require("prom-client");

promClient.collectDefaultMetrics();

const httpRequestsTotal = new promClient.Counter({
  name: "app_http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["method", "route", "status_code"],
});

const httpRequestDurationSeconds = new promClient.Histogram({
  name: "app_http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
});

const dbQueriesTotal = new promClient.Counter({
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

const labTestEndpointsEnabled = process.env.LAB_TEST_ENDPOINTS_ENABLED === "true";

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function queryDb() {
  const dbClient = new Client(dbConfig);
  await dbClient.connect();

  try {
    await dbClient.query("INSERT INTO visits DEFAULT VALUES");

    dbQueriesTotal.inc({
      operation: "insert_visit",
      status: "success",
    });

    const result = await dbClient.query(
      "SELECT COUNT(*) AS count FROM visits",
    );

    dbQueriesTotal.inc({
      operation: "count_visits",
      status: "success",
    });

    return result.rows[0].count;
  } catch (err) {
    dbQueriesTotal.inc({
      operation: "query",
      status: "error",
    });

    throw err;
  } finally {
    await dbClient.end();
  }
}

const server = http.createServer(async (req, res) => {
  const startedAt = process.hrtime.bigint();
  let route = "unknown";

  res.once("finish", () => {
    const durationSeconds =
      Number(process.hrtime.bigint() - startedAt) / 1_000_000_000;

    const labels = {
      method: req.method,
      route,
      status_code: String(res.statusCode),
    };

    httpRequestsTotal.inc(labels);
    httpRequestDurationSeconds.observe(labels, durationSeconds);
  });


  if (req.url === "/health") {
    route = "/health";

    res.writeHead(200, {
      "Content-Type": "text/plain",
    });
    res.end("OK\n");
    return;
  }

  if (req.url === "/metrics") {
    route = "/metrics",

    res.writeHead(200, {
      "Content-Type": promClient.register.contentType,
    });
    res.end(await promClient.register.metrics());
    return;
  }

  if (labTestEndpointsEnabled && req.url === "/slow") {
    route = "/slow";

    await sleep(1500);

    res.writeHead(200, {
      "Content-Type": "text/plain",
    });
    res.end("Slow response completed\n");
    return;
  }

  if (labTestEndpointsEnabled && req.url === "/error") {
    route = "/error";

    res.writeHead(500, {
      "Content-Type": "text/plain",
    });
    res.end("Intentional lab error\n");
    return;
  }

  if (req.url !== "/") {
    route = "unknown";

    res.writeHead(404, {
      "Content-Type": "text/plain",
    });
    res.end("Not Found\n");
    return;
  }

  route = "/";

  try {
    const count = await queryDb();

    res.writeHead(200, {
      "Content-Type": "text/plain",
    });
    res.end(`Hello from Node app container\nVisit count: ${count}\n`);
  } catch (err) {
    console.error(err);

    res.writeHead(500, {
      "Content-Type": "text/plain",
    });
    res.end(`DB error: ${err.message}\n`);
  }
});

server.listen(3000, "0.0.0.0", () => {
  console.log("App listening on port 3000");
});
