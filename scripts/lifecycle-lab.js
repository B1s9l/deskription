#!/usr/bin/env node
const fs = require("fs");
const os = require("os");
const path = require("path");
const {randomUUID} = require("crypto");
const root = path.join(os.tmpdir(), "deskriptions-lab");
const profiles = fs.existsSync(root) ? fs.readdirSync(root).filter(x => x.startsWith("profile-") && x.endsWith(".json")) : [];
if (profiles.length !== 1) {
  console.error(`Expected exactly one connected extension profile; found ${profiles.length}. Resolve explicitly: ${profiles.join(", ")}`);
  process.exit(2);
}
const identity = profiles[0].slice(8, -5);
const operationID = process.argv[2] || `lab-${randomUUID()}`;
const urls = ["https://example.com/?deskriptions=m1-a", "https://example.org/?deskriptions=m1-b"];
const commandPath = path.join(root, `command-${identity}.json`);
fs.writeFileSync(commandPath, JSON.stringify({type:"restoreTest", protocolVersion:1, operationID, urls}));
console.log(`Queued ${operationID}; waiting up to 20s for extension heartbeat.`);
const deadline = Date.now() + 20000;
const timer = setInterval(() => {
  const state = JSON.parse(fs.readFileSync(path.join(root, profiles[0]), "utf8"));
  if (state.type === "restoreResult" && state.operationID === operationID) {
    clearInterval(timer); console.log(JSON.stringify(state, null, 2)); process.exit(state.status === "complete" ? 0 : 1);
  }
  if (Date.now() > deadline) {
    clearInterval(timer); console.error("Timed out: extension missing, disabled, disconnected, or heartbeat delayed."); process.exit(3);
  }
}, 250);

