#!/usr/bin/env node
const {spawn} = require("child_process");
const path = require("path");
const fs = require("fs");
const os = require("os");
const host = process.argv[2] || path.join(__dirname, "..", ".build", "debug", "deskriptions-bridge");
const isolatedTmp = fs.mkdtempSync(path.join(os.tmpdir(), "deskriptions-native-host-test-"));

function exchange(message) {
  return new Promise((resolve, reject) => {
    const child = spawn(host, [], {stdio:["pipe", "pipe", "inherit"], env:{...process.env,TMPDIR:isolatedTmp}});
    const body = Buffer.from(JSON.stringify(message));
    const header = Buffer.alloc(4); header.writeUInt32LE(body.length); child.stdin.write(Buffer.concat([header, body]));
    let data = Buffer.alloc(0);
    const timeout = setTimeout(() => { child.kill(); reject(new Error("native messaging timed out")); }, 3000);
    child.stdout.on("data", chunk => {
      data = Buffer.concat([data, chunk]);
      if (data.length >= 4 && data.length >= 4 + data.readUInt32LE(0)) {
        clearTimeout(timeout); child.kill(); resolve(JSON.parse(data.subarray(4, 4 + data.readUInt32LE(0))));
      }
    });
    child.on("error", reject);
  });
}

(async () => {
  const base = {type:"inventory", savedStateVersion:1, adapterVersion:"test", installationID:"automated-test", sessionID:"session", browser:"com.google.Chrome", capabilities:["inventory.windows","inventory.fresh"], windows:[]};
  const current = await exchange({...base, protocolVersion:1});
  // A direct test process has no verified Chromium parent. Production must reject
  // the extension-supplied browser label rather than treating it as authoritative.
  if (current.code !== "unverified_browser_host") throw new Error(`Expected verified-parent rejection, received ${current.type}/${current.code}`);
  for (const version of [0, 2]) {
    const incompatible = await exchange({...base, protocolVersion:version});
    if (incompatible.code !== "incompatible_protocol" || !incompatible.supported?.includes(1)) throw new Error(`Protocol ${version} was not rejected safely`);
  }
  console.log("native messaging framing, protocol compatibility, and unverified-browser rejection: passed");
})().catch(error => { console.error(error); process.exitCode=1; }).finally(()=>fs.rmSync(isolatedTmp,{recursive:true,force:true}));
