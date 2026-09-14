'use strict';

/**
 * Real proxy I/O. The previous implementation handed the CONNECT tunnel to
 * `https.request` as a `socket` option — not a thing Node supports — so the
 * request silently opened a *direct* connection instead. Only an end-to-end
 * test catches that: every unit test of proxyForUrl() passed while the actual
 * download bypassed the proxy entirely.
 *
 * So this spins up a self-signed HTTPS origin plus a tiny CONNECT proxy, and
 * asserts the bytes arrived *and* that the proxy is the one who carried them.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');
const http = require('node:http');
const https = require('node:https');

const { openStream, fetchText } = require('../lib/download');
const { makeSelfSignedCert } = require('./helpers/tls');

const PAYLOAD = 'd4ab8c3ffe021f8d7caa841d3fc8e82ae251bafa33f8f73ac343d7fa14c72be4  asset.tar.gz\n';

const CERT = makeSelfSignedCert();

function listen(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
}

function close(server) {
  return new Promise((resolve) => server.close(() => resolve()));
}

/** HTTPS origin that records how it was reached. */
async function startOrigin(t, handler) {
  const hits = [];
  const server = https.createServer({ key: CERT.key, cert: CERT.cert }, (req, res) => {
    hits.push(req.url);
    if (handler) return handler(req, res);
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(PAYLOAD);
  });
  const port = await listen(server);
  t.after(() => close(server));
  return { port, hits };
}

/**
 * Minimal HTTP CONNECT proxy. Records every tunnel it is asked to open.
 * @param {{reject?: number}} [opts] reply with this status instead of tunnelling
 */
async function startProxy(t, opts = {}) {
  const connects = [];
  const server = http.createServer((req, res) => {
    res.writeHead(405).end('this proxy only speaks CONNECT');
  });
  server.on('connect', (req, clientSocket, head) => {
    connects.push(req.url);
    if (opts.reject) {
      clientSocket.end(`HTTP/1.1 ${opts.reject} Forbidden\r\n\r\n`);
      return;
    }
    const [host, port] = req.url.split(':');
    const upstream = net.connect(Number(port), host, () => {
      clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head && head.length) upstream.write(head);
      upstream.pipe(clientSocket);
      clientSocket.pipe(upstream);
    });
    upstream.on('error', () => clientSocket.destroy());
    clientSocket.on('error', () => upstream.destroy());
  });
  const port = await listen(server);
  t.after(() => close(server));
  return { port, connects };
}

test('the download really goes through the HTTPS_PROXY tunnel', { skip: !CERT }, async (t) => {
  const origin = await startOrigin(t);
  const proxy = await startProxy(t);

  const body = await fetchText(`https://localhost:${origin.port}/asset.sha256`, {
    env: { HTTPS_PROXY: `http://127.0.0.1:${proxy.port}` },
    tlsOptions: { ca: CERT.cert },
    timeoutMs: 10_000,
  });

  assert.equal(body, PAYLOAD, 'the payload must arrive intact through the tunnel');
  assert.deepEqual(
    proxy.connects,
    [`localhost:${origin.port}`],
    'the proxy must have been asked to tunnel to the origin — exactly once',
  );
  assert.deepEqual(origin.hits, ['/asset.sha256']);
});

test('a streamed body survives the tunnel in one piece', { skip: !CERT }, async (t) => {
  const big = 'x'.repeat(512 * 1024);
  const origin = await startOrigin(t, (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
    res.end(big);
  });
  const proxy = await startProxy(t);

  const res = await openStream(`https://localhost:${origin.port}/big.tar.gz`, {
    env: { HTTPS_PROXY: `http://127.0.0.1:${proxy.port}` },
    tlsOptions: { ca: CERT.cert },
    timeoutMs: 10_000,
  });
  const chunks = [];
  for await (const chunk of res) chunks.push(chunk);

  assert.equal(Buffer.concat(chunks).length, big.length);
  assert.equal(proxy.connects.length, 1);
});

test('NO_PROXY keeps the request off the proxy', { skip: !CERT }, async (t) => {
  const origin = await startOrigin(t);
  const proxy = await startProxy(t);

  const body = await fetchText(`https://localhost:${origin.port}/direct`, {
    env: { HTTPS_PROXY: `http://127.0.0.1:${proxy.port}`, NO_PROXY: 'localhost' },
    tlsOptions: { ca: CERT.cert },
    timeoutMs: 10_000,
  });

  assert.equal(body, PAYLOAD);
  assert.deepEqual(proxy.connects, [], 'NO_PROXY must bypass the tunnel entirely');
});

test('a redirect through the proxy opens a fresh tunnel and still lands', { skip: !CERT }, async (t) => {
  const origin = await startOrigin(t, (req, res) => {
    if (req.url === '/redirect') {
      res.writeHead(302, { Location: '/asset.sha256' });
      res.end();
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(PAYLOAD);
  });
  const proxy = await startProxy(t);

  const body = await fetchText(`https://localhost:${origin.port}/redirect`, {
    env: { HTTPS_PROXY: `http://127.0.0.1:${proxy.port}` },
    tlsOptions: { ca: CERT.cert },
    timeoutMs: 10_000,
  });

  assert.equal(body, PAYLOAD);
  assert.equal(proxy.connects.length, 2, 'one tunnel per hop');
});

test('a proxy that refuses the CONNECT surfaces as an error, not a silent direct fetch', { skip: !CERT }, async (t) => {
  const origin = await startOrigin(t);
  const proxy = await startProxy(t, { reject: 403 });

  await assert.rejects(
    () =>
      fetchText(`https://localhost:${origin.port}/asset.sha256`, {
        env: { HTTPS_PROXY: `http://127.0.0.1:${proxy.port}` },
        tlsOptions: { ca: CERT.cert },
        timeoutMs: 10_000,
      }),
    /Proxy CONNECT failed with status 403/,
  );
  assert.deepEqual(origin.hits, [], 'the origin must never be contacted directly');
});

test('an untrusted origin certificate is still rejected through the tunnel', { skip: !CERT }, async (t) => {
  const origin = await startOrigin(t);
  const proxy = await startProxy(t);

  // No `ca` this time: the tunnel must not become a way to skip TLS validation.
  await assert.rejects(
    () =>
      fetchText(`https://localhost:${origin.port}/asset.sha256`, {
        env: { HTTPS_PROXY: `http://127.0.0.1:${proxy.port}` },
        timeoutMs: 10_000,
      }),
    /self[- ]signed certificate|unable to verify/i,
  );
  assert.equal(proxy.connects.length, 1);
});
