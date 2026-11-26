#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..");
const PACKAGE = ROOT;

function waitForSocket(socketPath, child, timeoutMs = 10000) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (child.exitCode !== null) return reject(new Error(`bridge exited early with ${child.exitCode}`));
      try {
        if (fs.statSync(socketPath).isSocket()) return resolve();
      } catch {}
      if (Date.now() - started >= timeoutMs) return reject(new Error("bridge socket did not appear"));
      setTimeout(tick, 50);
    };
    tick();
  });
}

function request(socketPath, payload) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    let output = "";
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("bridge request timed out"));
    }, 10000);
    socket.setEncoding("utf8");
    socket.once("connect", () => socket.end(`${JSON.stringify(payload)}\n`));
    socket.on("data", (chunk) => { output += chunk; });
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    socket.once("end", () => {
      clearTimeout(timer);
      try { resolve(JSON.parse(output)); }
      catch (error) { reject(error); }
    });
  });
}

async function main() {
  if (process.platform !== "darwin") {
    console.log("SKIP test-apple-bridge-e2e (macOS only)");
    return;
  }
  const build = spawnSync("swift", ["build", "--package-path", PACKAGE, "-c", "debug"], {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 120000,
  });
  assert.equal(build.status, 0, build.stderr);
  const binPath = spawnSync("swift", ["build", "--package-path", PACKAGE, "-c", "debug", "--show-bin-path"], {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 30000,
  });
  assert.equal(binPath.status, 0, binPath.stderr);
  const binary = path.join(binPath.stdout.trim().split("\n").at(-1), "AgentAppleBridge");
  assert.ok(fs.existsSync(binary), "bridge binary must exist");

  const temp = fs.mkdtempSync("/tmp/bridge-e2e-");
  const socketPath = path.join(temp, "bridge.sock");
  const auditPath = path.join(temp, "audit.jsonl");
  const imsgLogPath = path.join(temp, "imsg-calls.jsonl");
  const imsgModePath = path.join(temp, "imsg-mode.txt");
  const darkEnv = { ...process.env, AGENT_BRIDGE_SOCKET: socketPath };
  delete darkEnv.AGENT_BRIDGE_ENABLED;
  const darkRun = spawnSync(binary, [], { env: darkEnv, encoding: "utf8", timeout: 10000 });
  assert.equal(darkRun.status, 0, darkRun.stderr);
  assert.equal(fs.existsSync(socketPath), false, "dark bridge must not bind its privileged socket");
  const imsgStub = path.join(temp, "imsg-stub.js");
  fs.writeFileSync(imsgStub, `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.IMSG_STUB_LOG, JSON.stringify(args) + "\\n");
if (args[0] === "status") {
  const mode = fs.existsSync(process.env.IMSG_STUB_MODE_FILE) ? fs.readFileSync(process.env.IMSG_STUB_MODE_FILE, "utf8").trim() : "";
  process.stdout.write(JSON.stringify({
    basic_features: true,
    advanced_features: mode !== "basic-only",
    v2_ready: mode !== "basic-only",
    rpc_methods: mode === "basic-only" ? [] : ["send","tapback","message.edit","message.unsend","message.delete","group.rename","group.setIcon","group.addParticipant","group.removeParticipant","group.leave","chats.delete","poll.send"]
  }));
} else if (args[0] === "search" && args.includes("permission-denied")) {
  process.stderr.write("Full Disk Access permission denied\\n");
  process.exit(1);
} else if (args[0] === "search" && args.includes("unsupported-command")) {
  process.stderr.write("unknown command\\n");
  process.exit(1);
} else if (args[0] === "search" && args.includes("ordinary-failure")) {
  process.stderr.write("backend unavailable\\n");
  process.exit(1);
} else if (args[0] === "search" && args.includes("malformed-output")) {
  process.stdout.write("{not-json}\\n");
} else if (args[0] === "search" && args.includes("empty-output")) {
  // Deliberately emit no rows.
} else if (["chats", "history", "search"].includes(args[0])) {
  const limitIndex = args.indexOf("--limit");
  const count = Math.min(Number(args[limitIndex + 1] || 1), 5);
  for (let index = 0; index < count; index += 1) {
    process.stdout.write(JSON.stringify({ id: "row-" + index, index }) + "\\n");
  }
} else {
  process.stdout.write(JSON.stringify({ argv: args }));
}
`);
  fs.chmodSync(imsgStub, 0o755);

  const child = spawn(binary, [], {
    env: {
      ...process.env,
      AGENT_BRIDGE_IMSG_PATH: imsgStub,
      IMSG_STUB_LOG: imsgLogPath,
      IMSG_STUB_MODE_FILE: imsgModePath,
      AGENT_BRIDGE_ENABLED: "1",
      AGENT_BRIDGE_ALLOW_UNSIGNED_TEST: "1",
      AGENT_BRIDGE_SOCKET: socketPath,
      AGENT_BRIDGE_AUDIT_PATH: auditPath,
      AGENT_BRIDGE_ALLOWED_ROOTS: temp,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  try {
    await waitForSocket(socketPath, child).catch(error => { throw new Error(`${error.message}: ${stderr}`); });
    const socketMode = fs.statSync(socketPath).mode & 0o777;
    assert.equal(socketMode, 0o600, "bridge socket must be owner-only");

    const reminderCaps = await request(socketPath, {
      version: 1, domain: "reminders", mode: "read", params: { action: "capabilities" },
    });
    assert.equal(reminderCaps.success, true);
    assert.ok(reminderCaps.result.write.includes("complete"));

    const noteCaps = await request(socketPath, {
      version: 1, domain: "notes", mode: "read", params: { action: "capabilities" },
    });
    assert.equal(noteCaps.success, true);
    assert.equal(noteCaps.result.fullBody, true);

    const messageCaps = await request(socketPath, {
      version: 1, domain: "messages", mode: "read", params: { action: "capabilities" },
    });
    assert.equal(messageCaps.success, true);
    assert.equal(messageCaps.result.v2_ready, true);

    const pagedMessages = await request(socketPath, {
      version: 1,
      domain: "messages",
      mode: "read",
      params: { action: "chats", cursor: "2", limit: 2 },
    });
    assert.equal(pagedMessages.success, true);
    assert.deepEqual(pagedMessages.result.items.map((row) => row.id), ["row-2", "row-3"]);
    assert.equal(pagedMessages.result.nextCursor, "4");
    const terminalPage = await request(socketPath, {
      version: 1,
      domain: "messages",
      mode: "read",
      params: { action: "chats", cursor: "4", limit: 2 },
    });
    assert.equal(terminalPage.success, true);
    assert.deepEqual(terminalPage.result.items.map((row) => row.id), ["row-4"]);
    assert.equal(terminalPage.result.nextCursor, null);

    const countCalls = () => fs.existsSync(imsgLogPath)
      ? fs.readFileSync(imsgLogPath, "utf8").trim().split("\n").filter(Boolean).length
      : 0;
    for (const cursor of ["-1", "abc", "200"]) {
      const before = countCalls();
      const invalidCursor = await request(socketPath, {
        version: 1,
        domain: "messages",
        mode: "read",
        params: { action: "chats", cursor, limit: 1 },
      });
      assert.equal(invalidCursor.success, false);
      assert.equal(invalidCursor.code, "invalid_cursor");
      assert.equal(countCalls(), before, "invalid cursor must not invoke imsg");
    }
    const emptyPage = await request(socketPath, {
      version: 1,
      domain: "messages",
      mode: "read",
      params: { action: "search", query: "empty-output", limit: 1 },
    });
    assert.equal(emptyPage.success, true);
    assert.deepEqual(emptyPage.result.items, []);
    assert.equal(emptyPage.result.nextCursor, null);

    const permissionFailure = await request(socketPath, {
      version: 1,
      domain: "messages",
      mode: "read",
      params: { action: "search", query: "permission-denied", limit: 1 },
    });
    assert.equal(permissionFailure.success, false);
    assert.equal(permissionFailure.code, "permission_required");
    for (const [query, code] of [
      ["malformed-output", "invalid_command_output"],
      ["unsupported-command", "unsupported_action"],
      ["ordinary-failure", "command_failed"],
    ]) {
      const failure = await request(socketPath, {
        version: 1,
        domain: "messages",
        mode: "read",
        params: { action: "search", query, limit: 1 },
      });
      assert.equal(failure.success, false, query);
      assert.equal(failure.code, code, query);
    }

    const dryRun = await request(socketPath, {
      version: 1,
      domain: "messages",
      mode: "write",
      params: { action: "send", target: { handle: "TEST-HANDLE" }, content: { text: "not sent" }, dryRun: true },
    });
    assert.equal(dryRun.success, true);
    assert.equal(dryRun.result.dryRun, true);

    const sendShape = await request(socketPath, {
      version: 1,
      domain: "messages",
      mode: "write",
      params: { action: "send", target: { handle: "TEST-HANDLE" }, content: { text: "stubbed" } },
    });
    assert.deepEqual(sendShape.result.argv, ["send", "--to", "TEST-HANDLE", "--text", "stubbed", "--json"]);

    const editShape = await request(socketPath, {
      version: 1,
      domain: "messages",
      mode: "write",
      params: {
        action: "edit",
        target: { chatGuid: "iMessage;-;TEST-HANDLE", messageId: "MESSAGE-GUID" },
        content: { text: "replacement" },
      },
    });
    assert.deepEqual(editShape.result.argv, [
      "edit", "--chat", "iMessage;-;TEST-HANDLE", "--message", "MESSAGE-GUID",
      "--new-text", "replacement", "--json",
    ]);

    fs.writeFileSync(imsgModePath, "basic-only");
    const unsupportedEdit = await request(socketPath, {
      version: 1,
      domain: "messages",
      mode: "write",
      params: {
        action: "edit",
        target: { chatGuid: "iMessage;-;TEST-HANDLE", messageId: "MESSAGE-GUID" },
        content: { text: "replacement" },
      },
    });
    assert.equal(unsupportedEdit.success, false);
    assert.equal(unsupportedEdit.code, "capability_unavailable");
    fs.writeFileSync(imsgModePath, "");

    const invocationCount = () => fs.existsSync(imsgLogPath)
      ? fs.readFileSync(imsgLogPath, "utf8").trim().split("\n").filter(Boolean).length
      : 0;
    for (const text of [
      "Bearer abcdefghijklmnopqrstuvwxyz123456",
      '{"path":"/private/example"}',
      "/private/example/private.txt",
      "sk-abcdefghijklmnopqrstuvwxyz",
      "a".repeat(64),
      "gateway.auth must stay private",
    ]) {
      const before = invocationCount();
      const blocked = await request(socketPath, {
        version: 1,
        domain: "messages",
        mode: "write",
        params: {
          action: "send",
          target: { handle: "TEST-HANDLE" },
          content: { text },
        },
      });
      assert.equal(blocked.success, false, text);
      assert.equal(blocked.code, "outbound_blocked", text);
      assert.equal(invocationCount(), before, "blocked content must not invoke imsg");
    }

    const blockedAttachment = await request(socketPath, {
      version: 1,
      domain: "messages",
      mode: "write",
      params: {
        action: "send",
        target: { handle: "TEST-HANDLE" },
        content: { file: "/etc/hosts" },
      },
    });
    assert.equal(blockedAttachment.success, false);
    assert.equal(blockedAttachment.code, "attachment_path_denied");

    const safeAttachment = path.join(temp, "safe.txt");
    fs.writeFileSync(safeAttachment, "safe attachment");
    const allowedAttachment = await request(socketPath, {
      version: 1,
      domain: "messages",
      mode: "write",
      params: {
        action: "send",
        target: { handle: "TEST-HANDLE" },
        content: { file: safeAttachment },
      },
    });
    assert.deepEqual(allowedAttachment.result.argv, [
      "send", "--to", "TEST-HANDLE", "--file", safeAttachment, "--json",
    ]);

    const secretAttachment = path.join(temp, "secret.txt");
    fs.writeFileSync(secretAttachment, "Bearer abcdefghijklmnopqrstuvwxyz123456");
    const scriptAttachment = path.join(temp, "unsafe.sh");
    fs.writeFileSync(scriptAttachment, "#!/bin/sh\n");
    const oversizedAttachment = path.join(temp, "oversized.txt");
    fs.writeFileSync(oversizedAttachment, "");
    fs.truncateSync(oversizedAttachment, 10 * 1024 * 1024 + 1);
    const invalidUtf8Attachment = path.join(temp, "invalid.txt");
    fs.writeFileSync(invalidUtf8Attachment, Buffer.from([0xff, 0xfe]));
    const symlinkAttachment = path.join(temp, "symlink.txt");
    fs.symlinkSync("/etc/hosts", symlinkAttachment);
    for (const [file, code] of [
      [secretAttachment, "outbound_blocked"],
      [scriptAttachment, "attachment_type_denied"],
      [oversizedAttachment, "attachment_too_large"],
      [invalidUtf8Attachment, "invalid_attachment"],
      [symlinkAttachment, "attachment_path_denied"],
      [temp, "invalid_attachment"],
    ]) {
      const before = invocationCount();
      const blocked = await request(socketPath, {
        version: 1,
        domain: "messages",
        mode: "write",
        params: {
          action: "send",
          target: { handle: "TEST-HANDLE" },
          content: { file },
        },
      });
      assert.equal(blocked.success, false, file);
      assert.equal(blocked.code, code, file);
      assert.equal(invocationCount(), before, "blocked attachment must not invoke imsg");
    }

    const invalid = await request(socketPath, {
      version: 1, domain: "calendar", mode: "read", params: { action: "list" },
    });
    assert.equal(invalid.success, false);
    assert.equal(invalid.code, "invalid_domain");

    const contactsWrite = await request(socketPath, {
      version: 1, domain: "contacts", mode: "write", params: { action: "create" },
    });
    assert.equal(contactsWrite.success, false);
    assert.equal(contactsWrite.code, "read_only", "Contacts must refuse writes before any TCC prompt");

    const auditRows = fs.readFileSync(auditPath, "utf8").trim().split("\n").map(JSON.parse);
    assert.ok(auditRows.length >= 6);
    assert.ok(auditRows.every((row) => /^[a-f0-9]{64}$/.test(row.payloadHash)));
    const auditText = fs.readFileSync(auditPath, "utf8");
    assert.equal(auditText.includes("TEST-HANDLE"), false, "audit must not contain recipient data");
    assert.equal(auditText.includes("replacement"), false, "audit must not contain message content");

    console.log("PASS test-apple-bridge-e2e");
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      await new Promise((resolve) => {
        child.once("exit", resolve).once("error", resolve);
        child.kill("SIGTERM");
      });
    }
    fs.rmSync(temp, { recursive: true, force: true });
  }
  assert.equal(stderr, "", stderr);
}

main().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});
