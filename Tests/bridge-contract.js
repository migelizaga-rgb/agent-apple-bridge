#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const root = path.resolve(__dirname, "..");
const bridge = root;
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");

for (const relative of [
  "Package.swift",
  "Resources/Info.plist.in",
  "Resources/AgentAppleBridge.entitlements",
  "Sources/AgentAppleBridge/main.swift",
  "Sources/AgentAppleBridge/UnixSocketServer.swift",
  "Sources/AgentAppleBridge/RemindersHandler.swift",
  "Sources/AgentAppleBridge/NotesHandler.swift",
  "Sources/AgentAppleBridge/MessagesHandler.swift",
  "Sources/AgentAppleBridge/ContactsHandler.swift",
  "Sources/AgentAppleBridge/GeneratedSecretRedactionPatterns.swift",
]) {
  assert.ok(fs.existsSync(path.join(root, relative)), `missing ${relative}`);
}

const info = read("Resources/Info.plist.in");
assert.match(info, /NSRemindersFullAccessUsageDescription/);
assert.match(info, /NSContactsUsageDescription/);
assert.match(info, /NSAppleEventsUsageDescription/);
const entitlements = read("Resources/AgentAppleBridge.entitlements");
assert.match(entitlements, /<key>com\.apple\.security\.personal-information\.addressbook<\/key>\s*<true\/>/,
  "hardened runtime refuses to prompt for Contacts without the addressbook entitlement");

const socket = read("Sources/AgentAppleBridge/UnixSocketServer.swift");
assert.match(socket, /getpeereid/);
assert.match(socket, /peerUID == geteuid/);
assert.match(socket, /chmod\(socketPath, 0o600\)/);

const main = read("Sources/AgentAppleBridge/main.swift");
const bridgeRequest = read("Sources/AgentAppleBridge/BridgeRequest.swift");
assert.match(bridgeRequest, /\["reminders", "notes", "messages", "contacts"\]/);
assert.match(bridgeRequest, /reminders, notes, messages, or contacts/);
const contacts = read("Sources/AgentAppleBridge/ContactsHandler.swift");
assert.match(contacts, /BridgeError\("read_only"/);
assert.match(contacts, /contactSummary\(_ contact: CNContact\) -> \[String: Any\]/);
assert.doesNotMatch(contacts, /store\.(save|remove)\(/, "Contacts handler must have no write path");
assert.match(main, /case "contacts":[\s\S]*contacts\.handle/);
assert.match(main, /domain":"contacts","mode":"read"/);
assert.match(main, /apple-bridge-audit\.jsonl/);
assert.doesNotMatch(main, /request\.params\]\s*[,}]/, "audit must not serialize raw params");
assert.match(main, /AGENT_BRIDGE_ENABLED/);
assert.match(main, /anchor apple generic/);
assert.match(main, /--verify/);
assert.match(main, /persistent_signing_required/);
assert.match(main, /#if DEBUG[\s\S]*AGENT_BRIDGE_ALLOW_UNSIGNED_TEST[\s\S]*#else[\s\S]*return false[\s\S]*#endif/,
  "unsigned bridge bypass must compile only into debug builds");

const reminders = read("Sources/AgentAppleBridge/RemindersHandler.swift");
assert.match(reminders, /requestFullAccessToReminders/);
assert.match(reminders, /forName: \.EKEventStoreChanged,[\s\S]*?object: store/,
  "Reminders store changes are observed on the bridge's EventKit store");
assert.match(reminders, /asyncAfter\(deadline: \.now\(\) \+ 3/,
  "Reminders change marker is debounced");
assert.match(reminders, /Library\/Application Support\/AgentAppleBridge[\s\S]*?reminders-changed/);
const bridgeMain = read("Sources/AgentAppleBridge/main.swift");
assert.match(bridgeMain, /Thread \{[\s\S]*?UnixSocketServer\(socketPath: socketPath, handler: route\)\.run\(\)/,
  "the blocking accept loop must run off the main thread");
assert.match(bridgeMain, /RunLoop\.main\.run\(\)\s*$/, "the main run loop must stay free for EventKit notifications");
assert.match(reminders, /Darwin\.rename/,
  "Reminders change marker is atomically replaced");
assert.match(reminders, /list_ambiguous[\s\S]*calendarIdentifier/);
assert.match(reminders, /Reminders list id was not found/);
assert.match(reminders, /target\.listId and target\.list identify different/);
assert.match(reminders, /store\.save/);
assert.match(reminders, /store\.remove/);

const notes = read("Sources/AgentAppleBridge/NotesHandler.swift");
assert.match(notes, /Application\("Notes"\)/);
assert.match(notes, /passwordProtected/);

const messages = read("Sources/AgentAppleBridge/MessagesHandler.swift");
assert.match(messages, /ProcessRunner\.json\(imsgPath/);
assert.match(messages, /dryRun/);
assert.match(messages, /OutboundGuard\.validateMessage/);

if (process.platform === "darwin" && spawnSync("swift", ["--version"]).status === 0) {
  const build = spawnSync("swift", ["build", "--package-path", bridge], {
    encoding: "utf8",
    timeout: 120000,
  });
  assert.equal(build.status, 0, build.stderr || build.stdout);
  const binPath = spawnSync("swift", ["build", "--package-path", bridge, "--show-bin-path"], { encoding: "utf8" }).stdout.trim();
  const selfTest = spawnSync(path.join(binPath, "AgentAppleBridge"), ["--self-test"], {
    encoding: "utf8",
    timeout: 10000,
  });
  assert.equal(selfTest.status, 0, selfTest.stderr || selfTest.stdout);
  assert.equal(JSON.parse(selfTest.stdout).ok, true);

  const releaseBuild = spawnSync("swift", ["build", "--package-path", bridge, "-c", "release"], {
    encoding: "utf8",
    timeout: 120000,
  });
  assert.equal(releaseBuild.status, 0, releaseBuild.stderr || releaseBuild.stdout);
  const releaseBinPath = spawnSync(
    "swift",
    ["build", "--package-path", bridge, "-c", "release", "--show-bin-path"],
    { encoding: "utf8" },
  ).stdout.trim();
  const releaseUnsignedBypass = spawnSync(path.join(releaseBinPath, "AgentAppleBridge"), [], {
    encoding: "utf8",
    timeout: 10000,
    env: {
      ...process.env,
      AGENT_BRIDGE_ENABLED: "1",
      AGENT_BRIDGE_ALLOW_UNSIGNED_TEST: "1",
    },
  });
  assert.equal(releaseUnsignedBypass.status, 78,
    "release bridge must reject an unsigned binary even when the debug bypass environment flag is set");
} else {
  assert.equal(os.platform() !== "darwin", true, "Swift is required for the macOS bridge build");
}

console.log("PASS test-apple-bridge-contract");
