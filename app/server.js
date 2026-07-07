const http = require("http");
const { Client } = require("pg");

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

  await client.query(`
    CREATE TABLE IF NOT EXISTS visits (
      id SERIAL PRIMARY KEY,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  `);

  await client.query("INSERT INTO visits DEFAULT VALUES");

  const result = await client.query("SELECT COUNT(*) AS count FROM visits");

  await client.end();

  return result.rows[0].count;
}

const server = http.createServer(async (req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("OK\n");
    return;
  }

  try {
    const count = await queryDb();

    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end(`Hello from Node app container\nVisit count: ${count}\n`);
  } catch (err) {
    console.error(err);

    res.writeHead(500, { "Content-Type": "text/plain" });
    res.end(`DB error: ${err.message}\n`);
  }
});

server.listen(3000, "0.0.0.0", () => {
  console.log("App listening on port 3000");
});
