const http = require("http");
const { Client } = require("pg");
const promClient = require("prom-client");

promClient.collectDefaultMetrics();

const httpRequestsTotal = new promClient.Counter({
  name: "app_http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["method", "route", "status_code"],
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
  if (req.url === "/health") {
    httpRequestsTotal.inc({
      method: req.method,
      route: "/health",
      status_code: "200",
    });

    res.writeHead(200, {
      "Content-Type": "text/plain",
    });
    res.end("OK\n");
    return;
  }

  if (req.url === "/metrics") {
    httpRequestsTotal.inc({
      method: req.method,
      route: "/metrics",
      status_code: "200",
    });

    res.writeHead(200, {
      "Content-Type": promClient.register.contentType,
    });
    res.end(await promClient.register.metrics());
    return;
  }

  try {
    const count = await queryDb();

    httpRequestsTotal.inc({
      method: req.method,
      route: "/",
      status_code: "200",
    });

    res.writeHead(200, {
      "Content-Type": "text/plain",
    });
    res.end(`Hello from Node app container\nVisit count: ${count}\n`);
  } catch (err) {
    console.error(err);

    httpRequestsTotal.inc({
      method: req.method,
      route: "/",
      status_code: "500",
    });

    res.writeHead(500, {
      "Content-Type": "text/plain",
    });
    res.end(`DB error: ${err.message}\n`);
  }
});

server.listen(3000, "0.0.0.0", () => {
  console.log("App listening on port 3000");
});
