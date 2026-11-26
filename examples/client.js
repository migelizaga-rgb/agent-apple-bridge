#!/usr/bin/env node
'use strict';
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const socketPath = process.env.AGENT_BRIDGE_SOCKET ||
  path.join(os.homedir(), 'Library/Application Support/AgentAppleBridge/apple-bridge.sock');
const socket = net.createConnection({ path: socketPath });
socket.setEncoding('utf8');
socket.setTimeout(10000, () => socket.destroy(new Error('request timed out')));
socket.on('connect', () => socket.end(JSON.stringify({
  version: 1, domain: 'notes', mode: 'read', params: { action: 'capabilities' }
}) + '\n'));
socket.on('data', chunk => process.stdout.write(chunk));
socket.on('error', error => { console.error(error.message); process.exitCode = 1; });
