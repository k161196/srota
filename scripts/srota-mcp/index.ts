import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { Database } from "bun:sqlite";
import { homedir } from "os";
import { join } from "path";

const DB_PATH = join(homedir(), ".srota", "srota.db");
const db = new Database(DB_PATH);
db.exec("PRAGMA journal_mode=WAL;");

const server = new Server(
  { name: "srota", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "list_features",
      description: "List all features with IDs, names, descriptions",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "get_feature",
      description: "Get a single feature by ID",
      inputSchema: {
        type: "object",
        properties: { id: { type: "string", description: "Feature ID" } },
        required: ["id"],
      },
    },
    {
      name: "update_feature_description",
      description: "Update feature's description. Markdown is rendered in UI.",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string", description: "Feature ID" },
          description: { type: "string", description: "New description (markdown supported)" },
        },
        required: ["id", "description"],
      },
    },
    {
      name: "list_issues",
      description: "List issues, optionally filtered by feature",
      inputSchema: {
        type: "object",
        properties: {
          feature_id: { type: "string", description: "Filter by feature ID (optional)" },
        },
      },
    },
    {
      name: "add_issue",
      description: "Create a new issue and optionally link it to a feature",
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string" },
          body: { type: "string" },
          status: { type: "string", enum: ["open", "in_progress", "closed"], default: "open" },
          feature_id: { type: "string", description: "Feature ID to link to (optional)" },
        },
        required: ["title"],
      },
    },
    {
      name: "update_issue",
      description: "Update issue fields",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string" },
          title: { type: "string" },
          body: { type: "string" },
          status: { type: "string", enum: ["open", "in_progress", "closed"] },
        },
        required: ["id"],
      },
    },
    {
      name: "link_issue_to_feature",
      description: "Link an existing issue to a feature",
      inputSchema: {
        type: "object",
        properties: {
          issue_id: { type: "string" },
          feature_id: { type: "string" },
        },
        required: ["issue_id", "feature_id"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args = {} } = req.params;

  try {
    switch (name) {
      case "list_features": {
        const rows = db.query("SELECT * FROM features ORDER BY name").all();
        return { content: [{ type: "text", text: JSON.stringify(rows, null, 2) }] };
      }

      case "get_feature": {
        const row = db.query("SELECT * FROM features WHERE id = ?").get((args as any).id);
        if (!row) return { content: [{ type: "text", text: "Feature not found" }], isError: true };
        return { content: [{ type: "text", text: JSON.stringify(row, null, 2) }] };
      }

      case "update_feature_description": {
        const a = args as any;
        const changes = db
          .query("UPDATE features SET description = ? WHERE id = ? RETURNING id")
          .all(a.description, a.id);
        if (!changes.length) return { content: [{ type: "text", text: "Feature not found" }], isError: true };
        return { content: [{ type: "text", text: "Description updated" }] };
      }

      case "list_issues": {
        const a = args as any;
        const rows = a.feature_id
          ? db.query("SELECT * FROM issues WHERE feature_id = ? ORDER BY title").all(a.feature_id)
          : db.query("SELECT * FROM issues ORDER BY title").all();
        return { content: [{ type: "text", text: JSON.stringify(rows, null, 2) }] };
      }

      case "add_issue": {
        const id = crypto.randomUUID();
        const a = args as any;
        db.run(
          "INSERT INTO issues (id, title, body, status, org_id, feature_id) VALUES (?, ?, ?, ?, '', ?)",
          [id, a.title, a.body ?? "", a.status ?? "open", a.feature_id ?? ""]
        );
        return { content: [{ type: "text", text: JSON.stringify({ id, title: a.title }) }] };
      }

      case "update_issue": {
        const a = args as any;
        const fields: string[] = [];
        const vals: unknown[] = [];
        if (a.title !== undefined) {
          fields.push("title = ?");
          vals.push(a.title);
        }
        if (a.body !== undefined) {
          fields.push("body = ?");
          vals.push(a.body);
        }
        if (a.status !== undefined) {
          fields.push("status = ?");
          vals.push(a.status);
        }
        if (!fields.length) return { content: [{ type: "text", text: "Nothing to update" }] };
        vals.push(a.id);
        db.run(`UPDATE issues SET ${fields.join(", ")} WHERE id = ?`, vals);
        return { content: [{ type: "text", text: "Issue updated" }] };
      }

      case "link_issue_to_feature": {
        const a = args as any;
        db.run("UPDATE issues SET feature_id = ? WHERE id = ?", [a.feature_id, a.issue_id]);
        return { content: [{ type: "text", text: "Issue linked to feature" }] };
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
