import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import net from "node:net";
import { createRelay } from "./server.mjs";

function listen(relay) {
  return new Promise((resolve) => {
    relay.server.listen(0, "127.0.0.1", () => resolve(relay.server.address().port));
  });
}

function connect(port) {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString("base64");
    const socket = new net.Socket();
    let buffer = Buffer.alloc(0);
    const frames = [];
    let opened = false;
    socket.connect(port, "127.0.0.1", () => {
      socket.write(
        "GET /v1/room HTTP/1.1\r\n" +
          "Host: 127.0.0.1\r\n" +
          "Upgrade: websocket\r\n" +
          "Connection: Upgrade\r\n" +
          `Sec-WebSocket-Key: ${key}\r\n` +
          "Sec-WebSocket-Version: 13\r\n\r\n"
      );
    });
    const api = {
      socket,
      frames,
      send(opcode, payload, { mask = true } = {}) {
        socket.write(clientFrame(opcode, Buffer.from(payload), mask));
      },
      async waitFor(predicate, timeout = 1000) {
        const start = Date.now();
        while (Date.now() - start < timeout) {
          if (predicate(frames)) return;
          await new Promise((resolve) => setTimeout(resolve, 15));
        }
        throw new Error("timed out");
      },
    };
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!opened) {
        const split = buffer.indexOf("\r\n\r\n");
        if (split < 0) return;
        const header = buffer.subarray(0, split).toString("utf8");
        if (!header.includes("101")) {
          reject(new Error(header.split("\r\n")[0]));
          socket.destroy();
          return;
        }
        buffer = buffer.subarray(split + 4);
        opened = true;
        resolve(api);
      }
      while (buffer.length >= 2) {
        const frame = readServerFrame(buffer);
        if (!frame) break;
        buffer = buffer.subarray(frame.bytes);
        frames.push(frame);
      }
    });
    socket.on("error", reject);
  });
}

function clientFrame(opcode, payload, mask) {
  const length = payload.length;
  let header;
  const maskBit = mask ? 0x80 : 0;
  if (length < 126) header = Buffer.from([0x80 | opcode, maskBit | length]);
  else {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = maskBit | 126;
    header.writeUInt16BE(length, 2);
  }
  if (!mask) return Buffer.concat([header, payload]);
  const maskKey = crypto.randomBytes(4);
  const masked = Buffer.alloc(payload.length);
  for (let i = 0; i < payload.length; i += 1) masked[i] = payload[i] ^ maskKey[i % 4];
  return Buffer.concat([header, maskKey, masked]);
}

function readServerFrame(buffer) {
  const b1 = buffer[1];
  let length = b1 & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
  }
  if (buffer.length < offset + length) return null;
  return {
    opcode: buffer[0] & 0x0f,
    payload: Buffer.from(buffer.subarray(offset, offset + length)),
    bytes: offset + length,
  };
}

async function auth(client, role, token) {
  client.send(1, JSON.stringify({ role, token }));
  await client.waitFor((frames) => frames.some((frame) => frame.opcode === 1 && frame.payload.toString().includes('"ok":true')));
}

test("health does not require a token", async () => {
  const logs = [];
  const relay = createRelay({ log: (entry) => logs.push(entry) });
  const port = await listen(relay);
  const response = await fetch(`http://127.0.0.1:${port}/health`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  relay.server.close();
});

test("a room accepts one host and one watch and forwards only ciphertext", async () => {
  const logs = [];
  const relay = createRelay({ log: (entry) => logs.push(entry) });
  const port = await listen(relay);
  const token = "roomtokenvalue0001";
  const host = await connect(port);
  const watch = await connect(port);
  await auth(host, "host", token);
  await auth(watch, "watch", token);
  const secret = Buffer.from("command-body-should-not-be-logged");
  watch.send(2, secret);
  await host.waitFor((frames) => frames.some((frame) => frame.opcode === 2 && frame.payload.equals(secret)));
  const stranger = await connect(port);
  await auth(stranger, "watch", "othertokenvalue0001");
  watch.send(2, Buffer.from("second-body"));
  await host.waitFor((frames) => frames.filter((frame) => frame.opcode === 2).length >= 2);
  await new Promise((resolve) => setTimeout(resolve, 80));
  assert.equal(stranger.frames.filter((frame) => frame.opcode === 2).length, 0);
  const dumped = JSON.stringify(logs);
  assert.equal(dumped.includes("command-body-should-not-be-logged"), false);
  assert.equal(dumped.includes(token), false);
  assert.equal(dumped.includes("second-body"), false);
  relay.server.close();
  host.socket.destroy();
  watch.socket.destroy();
  stranger.socket.destroy();
});

test("a bad token is rejected and is not logged", async () => {
  const logs = [];
  const relay = createRelay({ log: (entry) => logs.push(entry) });
  const port = await listen(relay);
  const client = await connect(port);
  const token = "not-a-valid-room-token-value";
  client.send(1, JSON.stringify({ role: "watch", token: "short" }));
  await client.waitFor((frames) => frames.some((frame) => frame.opcode === 8));
  assert.equal(JSON.stringify(logs).includes("short"), false);
  assert.equal(JSON.stringify(logs).includes(token), false);
  relay.server.close();
  client.socket.destroy();
});

test("text after auth is not forwarded", async () => {
  const relay = createRelay({ log: () => {} });
  const port = await listen(relay);
  const token = "roomtokenvalue0002";
  const host = await connect(port);
  const watch = await connect(port);
  await auth(host, "host", token);
  await auth(watch, "watch", token);
  watch.send(1, "plain command");
  await watch.waitFor((frames) => frames.some((frame) => frame.opcode === 8));
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(host.frames.some((frame) => frame.opcode === 1 && frame.payload.toString().includes("plain command")), false);
  relay.server.close();
  host.socket.destroy();
  watch.socket.destroy();
});

test("message rate limit closes the socket", async () => {
  const relay = createRelay({ log: () => {}, ratePer10s: 3 });
  const port = await listen(relay);
  const client = await connect(port);
  await auth(client, "host", "roomtokenvalue0003");
  client.send(2, Buffer.from("one"));
  client.send(2, Buffer.from("two"));
  client.send(2, Buffer.from("three"));
  client.send(2, Buffer.from("four"));
  await client.waitFor((frames) => frames.some((frame) => frame.opcode === 8));
  relay.server.close();
  client.socket.destroy();
});
