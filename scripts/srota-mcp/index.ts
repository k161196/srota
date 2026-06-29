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
  "ALTER TABLE issues ADD COLUMN external_id TEXT NOT NULL DEFAULT ''",
  "ALTER TABLE issues ADD COLUMN external_url TEXT NOT NULL DEFAULT ''",
  "ALTER TABLE issues ADD COLUMN source TEXT NOT NULL DEFAULT ''",
  "ALTER TABLE issues ADD COLUMN external_status TEXT NOT NULL DEFAULT ''",
  "CREATE TABLE IF NOT EXISTS issue_repos (id TEXT PRIMARY KEY, issue_id TEXT NOT NULL, repo_id TEXT NOT NULL, branch TEXT NOT NULL DEFAULT '')",
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
          org_id: { type: "string", description: "Organization ID" },
          feature_id: { type: "string", description: "Feature ID to link to" },
          external_id: { type: "string", description: "External issue key, e.g. PROJ-42" },
          external_url: { type: "string", description: "URL to the issue in Jira/GitHub" },
          source: { type: "string", enum: ["jira", "github", "other"], description: "Source system" },
          external_status: { type: "string", description: "Raw status string from source" },
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
    {
      name: "add_feature",
      description: "Create a new feature",
      inputSchema: {
        type: "object",
        properties: {
          name: { type: "string" },
          project_id: { type: "string", description: "Project ID (get from list_features or list_projects)" },
          description: { type: "string" },
        },
        required: ["name"],
      },
    },
    {
      name: "list_organizations",
      description: "List all organizations with IDs and names",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "add_organization",
      description: "Create a new organization",
      inputSchema: {
        type: "object",
        properties: { name: { type: "string" } },
        required: ["name"],
      },
    },
    {
      name: "list_projects",
      description: "List all projects with IDs and names",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "add_project",
      description: "Create a new project under an organization",
      inputSchema: {
        type: "object",
        properties: {
          name: { type: "string" },
          org_id: { type: "string" },
          description: { type: "string" },
        },
        required: ["name", "org_id"],
      },
    },
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
      name: "get_repos_for_feature",
      description: "Get repos and their base branches linked to a feature",
      inputSchema: {
        type: "object",
        properties: {
          feature_id: { type: "string" },
        },
        required: ["feature_id"],
      },
    },
    {
      name: "add_feature_repo",
      description: "Link a repo+branch to a feature",
      inputSchema: {
        type: "object",
        properties: {
          feature_id: { type: "string" },
          repo_id: { type: "string" },
          branch: { type: "string", description: "Base branch for this feature in the repo" },
        },
        required: ["feature_id", "repo_id", "branch"],
      },
    },
    {
      name: "add_issue_repo",
      description: "Link a repo+branch to an issue (after creating the git branch)",
      inputSchema: {
        type: "object",
        properties: {
          issue_id: { type: "string" },
          repo_id: { type: "string" },
          branch: { type: "string", description: "The issue branch name, e.g. issue/PROJ-42-7-slug" },
        },
        required: ["issue_id", "repo_id", "branch"],
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
        const numRow = db.query("SELECT COALESCE(MAX(number), 0) + 1 AS n FROM issues").get() as any;
        const number = numRow?.n ?? 1;
        db.run(
          "INSERT INTO issues (id, title, body, status, org_id, feature_id, number, external_id, external_url, source, external_status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [id, a.title, a.body ?? "", a.status ?? "open", a.org_id ?? "", a.feature_id ?? "", number, a.external_id ?? "", a.external_url ?? "", a.source ?? "", a.external_status ?? ""]
        );
        return { content: [{ type: "text", text: JSON.stringify({ id, number, title: a.title }) }] };
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

      case "add_feature": {
        const a = args as any;
        const id = crypto.randomUUID();
        const numRow = db.query("SELECT COALESCE(MAX(number), 0) + 1 AS n FROM features").get() as any;
        const number = numRow?.n ?? 1;
        db.run(
          "INSERT INTO features (id, project_id, name, description, number) VALUES (?, ?, ?, ?, ?)",
          [id, a.project_id ?? "", a.name, a.description ?? "", number]
        );
        return { content: [{ type: "text", text: JSON.stringify({ id, name: a.name, number }) }] };
      }

      case "list_organizations": {
        const rows = db.query("SELECT id, name FROM organizations ORDER BY name").all();
        return { content: [{ type: "text", text: JSON.stringify(rows, null, 2) }] };
      }

      case "add_organization": {
        const a = args as any;
        const id = crypto.randomUUID();
        db.run("INSERT INTO organizations (id, name, path) VALUES (?, ?, '')", [id, a.name]);
        return { content: [{ type: "text", text: JSON.stringify({ id, name: a.name }) }] };
      }

      case "list_projects": {
        const rows = db.query("SELECT id, org_id, name, path, description FROM projects ORDER BY name").all();
        return { content: [{ type: "text", text: JSON.stringify(rows, null, 2) }] };
      }

      case "add_project": {
        const a = args as any;
        const id = crypto.randomUUID();
        db.run(
          "INSERT INTO projects (id, org_id, name, path, description) VALUES (?, ?, ?, '', ?)",
          [id, a.org_id, a.name, a.description ?? ""]
        );
        return { content: [{ type: "text", text: JSON.stringify({ id, name: a.name }) }] };
      }

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

      case "get_repos_for_feature": {
        const a = args as any;
        const rows = db.query(`
          SELECT r.id, r.name, r.local_path, fr.branch
          FROM feature_repos fr
          JOIN repos r ON r.id = fr.repo_id
          WHERE fr.feature_id = ?
          ORDER BY r.name
        `).all(a.feature_id);
        return { content: [{ type: "text", text: JSON.stringify(rows, null, 2) }] };
      }

      case "add_feature_repo": {
        const a = args as any;
        const id = crypto.randomUUID();
        db.run(
          "INSERT INTO feature_repos (id, feature_id, repo_id, branch) VALUES (?, ?, ?, ?)",
          [id, a.feature_id, a.repo_id, a.branch]
        );
        return { content: [{ type: "text", text: "Repo linked to feature" }] };
      }

      case "add_issue_repo": {
        const a = args as any;
        const id = crypto.randomUUID();
        db.run(
          "INSERT INTO issue_repos (id, issue_id, repo_id, branch) VALUES (?, ?, ?, ?)",
          [id, a.issue_id, a.repo_id, a.branch]
        );
        return { content: [{ type: "text", text: "Repo linked to issue" }] };
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
