import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { Database } from "bun:sqlite";
import { homedir } from "os";
import { basename, join } from "path";

function resolveDbPath(): string {
  if (process.env.SROTA_DB_PATH) return process.env.SROTA_DB_PATH;
  // When installed: ~/.srota[-debug]/srota-mcp/index.ts — derive from parent dir name
  const srotaDir = join(import.meta.dir, "..");
  const dirName = basename(srotaDir);
  if (dirName === ".srota-debug") return join(srotaDir, "srota_debug.db");
  if (dirName === ".srota") return join(srotaDir, "srota.db");
  // Dev source — default to debug db (most common dev workflow)
  return join(homedir(), ".srota-debug", "srota_debug.db");
}

const DB_PATH = resolveDbPath();
const db = new Database(DB_PATH);
db.exec("PRAGMA journal_mode=WAL;");

// Migrations — safe to re-run (ALTER TABLE is no-op if column exists in SQLite... actually it errors, so try/catch each)
for (const sql of [
  "ALTER TABLE repos ADD COLUMN default_branch TEXT NOT NULL DEFAULT 'main'",
]) {
  try { db.exec(sql); } catch {}
}

const server = new Server(
  { name: "srota", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "add_repo",
      description: "Create a new repo record",
      inputSchema: {
        type: "object",
        properties: {
          name: { type: "string" },
          url: { type: "string" },
          default_branch: { type: "string", description: "Default branch name, e.g. main or master" },
        },
        required: ["name"],
      },
    },
    {
      name: "list_repos",
      description: "List all repos with IDs, names, and local paths",
      inputSchema: { type: "object", properties: {} },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args = {} } = req.params;

  try {
    switch (name) {
      case "add_repo": {
        const a = args as any;
        const id = crypto.randomUUID();
        db.run(
          "INSERT INTO repos (id, name, url, default_branch) VALUES (?, ?, ?, ?)",
          [id, a.name, a.url ?? "", a.default_branch ?? "main"]
        );
        return { content: [{ type: "text", text: JSON.stringify({ id, name: a.name }) }] };
      }

      case "list_repos": {
        const rows = db.query("SELECT id, name, url, default_branch FROM repos ORDER BY name").all();
        return { content: [{ type: "text", text: JSON.stringify(rows, null, 2) }] };
      }

      default:
        return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
    }
  } catch (e: unknown) {
    return { content: [{ type: "text", text: (e as Error).message }], isError: true };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
