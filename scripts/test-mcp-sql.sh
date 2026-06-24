#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/srota-mcp"

bun - <<'TS'
import { Database } from "bun:sqlite";

const db = new Database(":memory:");
db.exec(`
  CREATE TABLE features (id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '');
  CREATE TABLE issues (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'open',
    org_id TEXT NOT NULL DEFAULT '',
    feature_id TEXT NOT NULL DEFAULT ''
  );
  INSERT INTO features (id, name, description) VALUES ('feature-1', 'Feature', '');
  INSERT INTO issues (id, title, body, status, org_id, feature_id)
    VALUES ('issue-1', 'Issue', '', 'open', '', 'feature-1');
`);

const queries = [
  ["list features", () => db.query("SELECT * FROM features ORDER BY name").all()],
  ["get feature", () => db.query("SELECT * FROM features WHERE id = ?").get("feature-1")],
  [
    "update feature",
    () => db.query("UPDATE features SET description = ? WHERE id = ? RETURNING id").all("new", "feature-1"),
  ],
  ["list issues for feature", () => db.query("SELECT * FROM issues WHERE feature_id = ? ORDER BY title").all("feature-1")],
  ["list issues", () => db.query("SELECT * FROM issues ORDER BY title").all()],
];

for (const [name, run] of queries) {
  run();
  console.log(`ok - ${name}`);
}
TS
