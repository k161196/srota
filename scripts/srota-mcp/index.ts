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
  "ALTER TABLE session_steps ADD COLUMN tag TEXT NOT NULL DEFAULT 'agent'",
]) {
  try { db.exec(sql); } catch {}
}

// sessions/session_steps: same schema as WorkspaceDB.swift's createTables() — CREATE TABLE IF
// NOT EXISTS is idempotent, so this is safe even if the Swift app hasn't created them yet
// (e.g. a fresh debug db with the MCP server started first).
db.exec(`
  CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    pane_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    external_session_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    summary TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    ended_at INTEGER
  );
  CREATE TABLE IF NOT EXISTS session_steps (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    hook_event TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'raw',
    tag TEXT NOT NULL DEFAULT 'agent',
    created_at INTEGER NOT NULL
  );
`);

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
    {
      name: "add_session_note",
      description:
        "Log a short progress note to this pane's session timeline, visible live in the Srota app " +
        "(pane header icon + timeline sidebar). Call this when your plan changes, you finish a " +
        "meaningful chunk of work, or you're about to do something the user should see coming " +
        "(a risky command, a big refactor, switching approach) — not for every small step. Keep " +
        "title to a few words and description to one or two sentences.",
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string", description: "Short label, a few words" },
          description: { type: "string", description: "One or two sentences of detail" },
        },
        required: ["title"],
      },
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

      case "add_session_note": {
        const a = args as any;
        const paneID = process.env.SROTA_PANE_ID;
        if (!paneID) {
          return {
            content: [{ type: "text", text: "SROTA_PANE_ID is not set — this MCP server isn't running inside a Srota pane" }],
            isError: true,
          };
        }
        const now = Math.floor(Date.now() / 1000);
        // Attach to whichever session is current for this pane — same "latest by created_at"
        // lookup WorkspaceDB.swift's currentSessionSteps() uses. Creates a placeholder session
        // if none exists yet (e.g. called before any hook has fired), rather than dropping the note.
        const existing = db
          .query("SELECT id FROM sessions WHERE pane_id = ? ORDER BY created_at DESC LIMIT 1")
          .get(paneID) as { id: string } | null;
        const sessionID = existing?.id ?? crypto.randomUUID();
        if (!existing) {
          db.run(
            "INSERT INTO sessions (id, pane_id, provider, external_session_id, title, summary, created_at, ended_at) VALUES (?, ?, '', '', '', '', ?, NULL)",
            [sessionID, paneID, now]
          );
        }
        // source='raw': not model-generated (that column is strictly "was this
        // FoundationModels-summarized or literal text"), just this note's own literal wording.
        // tag='mcp' carries the actual attribution.
        db.run(
          "INSERT INTO session_steps (id, session_id, hook_event, title, description, source, tag, created_at) VALUES (?, ?, 'AgentReported', ?, ?, 'raw', 'mcp', ?)",
          [crypto.randomUUID(), sessionID, a.title, a.description ?? "", now]
        );
        return { content: [{ type: "text", text: "logged" }] };
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
