/**
 * Outbound ciphertext relay for Watch Remote.
 *
 * The host agent and the Watch each open a WebSocket. The first text frame
 * is the room token. Every later frame is binary ciphertext and is forwarded
 * to the other peer. This process does not decrypt, and it does not log
 * tokens or frame bodies.
 *
 * Nothing here is deployed. Run it only where you choose to host it.
 */
import http from "node:http";
import https from "node:https";
import fs from "node:fs";
import crypto from "node:crypto";

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const MAX_FRAME = 256 * 1024;
const TOKEN_RE = /^[A-Za-z0-9_-]{16,128}$/;

export function createRelay(options = {}) {
  const ratePer10s = numberOption(options.ratePer10s, process.env.WATCHREMOTE_OUTBOUND_RATE, 40);
  const upgradesPerMinute = numberOption(options.upgradesPerMinute, process.env.WATCHREMOTE_OUTBOUND_UPGRADES, 30);
  const maxConnections = numberOption(options.maxConnections, process.env.WATCHREMOTE_OUTBOUND_MAX, 200);
  const authFailuresPerMinute = numberOption(options.authFailuresPerMinute, process.env.WATCHREMOTE_OUTBOUND_AUTH_FAILURES, 8);
  const log = options.log ?? defaultLog;
  const rooms = new Map();
  const limits = new Map();
  let connections = 0;

  function note(event, extra = {}) {
    const safe = { event };
    if (extra.role === "host" || extra.role === "watch") safe.role = extra.role;
    if (typeof extra.room === "string") safe.room = extra.room.slice(0, 8);
    log(safe);
  }

  function limited(ip, bucket, max, windowMs) {
    const now = Date.now();
    const key = `${ip}:${bucket}`;
    let row = limits.get(key);
    if (!row || now >= row.reset) {
      row = { count: 0, reset: now + windowMs };
      limits.set(key, row);
    }
    row.count += 1;
    return row.count > max;
  }

  function roomFor(token) {
    const id = crypto.createHash("sha256").update(token).digest("hex");
    let room = rooms.get(id);
    if (!room) {
      room = { id, host: null, watch: null, queue: { host: [], watch: [] } };
      rooms.set(id, room);
    }
    return room;
  }

  function dropRoom(room) {
    if (!room.host && !room.watch && room.queue.host.length === 0 && room.queue.watch.length === 0) {
      rooms.delete(room.id);
    }
  }

  const server = http.createServer((req, res) => {
    if (req.method === "GET" && (req.url === "/health" || req.url === "/health/")) {
      res.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
      res.end('{"ok":true}\n');
      return;
    }
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("Not found\n");
  });

  server.on("upgrade", (req, socket, head) => {
    const ip = req.socket.remoteAddress || "unknown";
    const path = (req.url || "").split("?")[0];
    if (path !== "/v1/room") {
      refuse(socket, 404);
      return;
    }
    if (limits.get(`${ip}:auth`)?.blocked) {
      note("rate");
      refuse(socket, 429);
      return;
    }
    if (connections >= maxConnections || limited(ip, "upgrade", upgradesPerMinute, 60_000)) {
      note("rate");
      refuse(socket, 429);
      return;
    }
    const key = req.headers["sec-websocket-key"];
    if (!key || String(req.headers.upgrade || "").toLowerCase() !== "websocket") {
      refuse(socket, 400);
      return;
    }
    const accept = crypto.createHash("sha1").update(String(key) + GUID).digest("base64");
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n` +
        "\r\n"
    );
    connections += 1;
    const peer = {
      socket,
      buffer: head && head.length ? Buffer.from(head) : Buffer.alloc(0),
      authed: false,
      role: null,
      room: null,
      fragments: Buffer.alloc(0),
      recent: [],
      ip,
    };
    const authTimer = setTimeout(() => {
      if (!peer.authed) closePeer(peer, 4401);
    }, 5_000);
    authTimer.unref?.();

    socket.on("data", (chunk) => {
      peer.buffer = Buffer.concat([peer.buffer, chunk]);
      try {
        drain(peer);
      } catch {
        closePeer(peer, 1002);
      }
    });
    socket.on("close", () => detach(peer));
    socket.on("error", () => detach(peer));
    if (peer.buffer.length) drain(peer);

    function detach(current) {
      if (current.closed) return;
      current.closed = true;
      clearTimeout(authTimer);
      connections = Math.max(0, connections - 1);
      const room = current.room;
      if (room && current.role && room[current.role] === current) {
        room[current.role] = null;
        note("left", { role: current.role, room: room.id });
        dropRoom(room);
      }
    }

    function drain(current) {
      while (current.buffer.length >= 2 && !current.closed) {
        const parsed = readFrame(current.buffer);
        if (!parsed) return;
        current.buffer = current.buffer.subarray(parsed.bytes);
        if (parsed.opcode === 8) {
          closePeer(current, 1000);
          return;
        }
        if (parsed.opcode === 9) {
          sendFrame(current.socket, 0xa, parsed.payload);
          continue;
        }
        if (parsed.opcode === 10) continue;
        if (parsed.opcode === 0) {
          current.fragments = Buffer.concat([current.fragments, parsed.payload]);
          continue;
        }
        let payload = parsed.payload;
        let opcode = parsed.opcode;
        if (parsed.fin === 0) {
          current.fragments = Buffer.concat([current.fragments, payload]);
          current.fragmentOpcode = opcode;
          continue;
        }
        if (current.fragments.length) {
          payload = Buffer.concat([current.fragments, payload]);
          opcode = current.fragmentOpcode || opcode;
          current.fragments = Buffer.alloc(0);
        }
        onMessage(current, opcode, payload);
      }
    }

    function onMessage(current, opcode, payload) {
      if (payload.length > MAX_FRAME) {
        closePeer(current, 1009);
        return;
      }
      const now = Date.now();
      current.recent = current.recent.filter((stamp) => now - stamp < 10_000);
      current.recent.push(now);
      if (current.recent.length > ratePer10s) {
        note("rate");
        closePeer(current, 4429);
        return;
      }
      if (!current.authed) {
        if (opcode !== 1) {
          failAuth(current);
          return;
        }
        let body;
        try {
          body = JSON.parse(payload.toString("utf8"));
        } catch {
          failAuth(current);
          return;
        }
        const role = body?.role;
        const token = body?.token;
        if ((role !== "host" && role !== "watch") || typeof token !== "string" || !TOKEN_RE.test(token)) {
          failAuth(current);
          return;
        }
        const room = roomFor(token);
        const previous = room[role];
        if (previous && previous !== current) closePeer(previous, 4001);
        current.authed = true;
        current.role = role;
        current.room = room;
        room[role] = current;
        clearTimeout(authTimer);
        sendFrame(current.socket, 1, Buffer.from('{"ok":true}'));
        note("joined", { role, room: room.id });
        const queued = room.queue[role];
        room.queue[role] = [];
        for (const frame of queued) sendFrame(current.socket, 2, frame);
        return;
      }
      if (opcode !== 2) {
        closePeer(current, 1003);
        return;
      }
      const otherRole = current.role === "host" ? "watch" : "host";
      const other = current.room[otherRole];
      if (other && !other.closed) {
        sendFrame(other.socket, 2, payload);
      } else if (current.room.queue[otherRole].length < 32) {
        current.room.queue[otherRole].push(Buffer.from(payload));
      }
    }

    function failAuth(current) {
      if (limited(ip, "auth", authFailuresPerMinute, 60_000)) {
        const row = limits.get(`${ip}:auth`);
        if (row) row.blocked = true;
        note("rate");
      } else {
        note("auth-failed");
      }
      closePeer(current, 4401);
    }
  });

  function closePeer(peer, code) {
    if (!peer || peer.closed) return;
    try {
      const reason = Buffer.alloc(0);
      const body = Buffer.alloc(2 + reason.length);
      body.writeUInt16BE(code, 0);
      sendFrame(peer.socket, 0x8, body);
      peer.socket.end();
    } catch {
      try { peer.socket.destroy(); } catch { /* already gone */ }
    }
  }

  return {
    server,
    rooms,
    closePeer,
    requestHandler: server.listeners("request")[0],
    upgradeHandler: server.listeners("upgrade")[0],
  };
}

function refuse(socket, status) {
  const text = status === 429 ? "Too many requests\n" : "Not found\n";
  try {
    socket.write(`HTTP/1.1 ${status} ${status === 429 ? "Too Many Requests" : "Error"}\r\nContent-Length: ${Buffer.byteLength(text)}\r\nConnection: close\r\n\r\n${text}`);
    socket.end();
  } catch {
    socket.destroy();
  }
}

function readFrame(buffer) {
  if (buffer.length < 2) return null;
  const b0 = buffer[0];
  const b1 = buffer[1];
  const fin = (b0 & 0x80) >> 7;
  const opcode = b0 & 0x0f;
  const masked = (b1 & 0x80) !== 0;
  let length = b1 & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
  } else if (length === 127) {
    if (buffer.length < 10) return null;
    const big = buffer.readBigUInt64BE(2);
    if (big > BigInt(MAX_FRAME)) {
      const error = new Error("frame");
      throw error;
    }
    length = Number(big);
    offset = 10;
  }
  if (length > MAX_FRAME) throw new Error("frame");
  if (!masked) throw new Error("mask");
  const maskLength = masked ? 4 : 0;
  if (buffer.length < offset + maskLength + length) return null;
  let payload = buffer.subarray(offset + maskLength, offset + maskLength + length);
  if (masked) {
    const mask = buffer.subarray(offset, offset + 4);
    const out = Buffer.alloc(payload.length);
    for (let i = 0; i < payload.length; i += 1) out[i] = payload[i] ^ mask[i % 4];
    payload = out;
  } else {
    payload = Buffer.from(payload);
  }
  return { fin, opcode, payload, bytes: offset + maskLength + length };
}

function sendFrame(socket, opcode, payload) {
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.from([0x80 | opcode, length]);
  } else if (length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

function defaultLog(entry) {
  process.stdout.write(`${JSON.stringify(entry)}\n`);
}

function numberOption(value, env, fallback) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = Number(env);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function listen(server, bind, port) {
  return new Promise((resolve) => {
    server.listen(port, bind, () => resolve(server.address()));
  });
}

async function main() {
  const bind = process.env.WATCHREMOTE_OUTBOUND_BIND || "127.0.0.1";
  const port = Number(process.env.WATCHREMOTE_OUTBOUND_PORT || 8787);
  const certPath = process.env.WATCHREMOTE_OUTBOUND_TLS_CERT || "";
  const keyPath = process.env.WATCHREMOTE_OUTBOUND_TLS_KEY || "";
  const relay = createRelay();
  let server = relay.server;
  if (certPath && keyPath) {
    server = https.createServer(
      { cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) },
      relay.requestHandler
    );
    server.on("upgrade", relay.upgradeHandler);
  }
  const address = await listen(server, bind, port);
  defaultLog({ event: "listening", port: address.port });
}

const isMain = process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop());
if (isMain) {
  main().catch((error) => {
    defaultLog({ event: "stopped" });
    process.stderr.write("The outbound relay stopped.\n");
    process.exitCode = 1;
    void error;
  });
}
