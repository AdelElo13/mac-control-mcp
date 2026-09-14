'use strict';

/**
 * Minimal HTTPS download with redirect following and HTTPS_PROXY support,
 * built on node: built-ins only. The package deliberately ships with zero
 * runtime dependencies: a postinstall script that pulls a dependency tree is
 * a supply-chain surface we do not want in front of a signed, notarized
 * binary.
 */

const https = require('node:https');
const http = require('node:http');
const { URL } = require('node:url');

const MAX_REDIRECTS = 5;
const DEFAULT_TIMEOUT_MS = 60_000;
const USER_AGENT = 'mac-control-mcp-npm-installer';

/**
 * Resolve the proxy to use for a target URL, honouring the conventional
 * environment variables (including NO_PROXY exclusions).
 *
 * @param {string} targetUrl
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {string|null} proxy URL or null
 */
function proxyForUrl(targetUrl, env = process.env) {
  const target = new URL(targetUrl);
  const noProxy = env.NO_PROXY || env.no_proxy || '';
  if (noProxy.trim() === '*') return null;
  const hostname = target.hostname.toLowerCase();
  for (const raw of noProxy.split(',')) {
    const entry = raw.trim().toLowerCase().replace(/^\./, '');
    if (entry === '') continue;
    if (hostname === entry || hostname.endsWith(`.${entry}`)) return null;
  }
  const proxy =
    target.protocol === 'https:'
      ? env.HTTPS_PROXY || env.https_proxy || env.ALL_PROXY || env.all_proxy
      : env.HTTP_PROXY || env.http_proxy || env.ALL_PROXY || env.all_proxy;
  return proxy && proxy.trim() !== '' ? proxy.trim() : null;
}

/**
 * Open a TCP tunnel through an HTTP proxy with CONNECT.
 *
 * @param {string} proxyUrl
 * @param {URL} target
 * @param {number} timeoutMs
 * @returns {Promise<import('node:net').Socket>}
 */
function connectThroughProxy(proxyUrl, target, timeoutMs) {
  return new Promise((resolve, reject) => {
    const proxy = new URL(proxyUrl);
    const transport = proxy.protocol === 'https:' ? https : http;
    const port = target.port || (target.protocol === 'https:' ? 443 : 80);
    /** @type {Record<string, string>} */
    const headers = { Host: `${target.hostname}:${port}` };
    if (proxy.username) {
      const creds = `${decodeURIComponent(proxy.username)}:${decodeURIComponent(proxy.password)}`;
      headers['Proxy-Authorization'] = `Basic ${Buffer.from(creds).toString('base64')}`;
    }
    const req = transport.request({
      host: proxy.hostname,
      port: proxy.port || (proxy.protocol === 'https:' ? 443 : 80),
      method: 'CONNECT',
      path: `${target.hostname}:${port}`,
      headers,
      timeout: timeoutMs,
    });
    req.once('connect', (res, socket) => {
      if (res.statusCode !== 200) {
        socket.destroy();
        const err = new Error(`Proxy CONNECT failed with status ${res.statusCode}`);
        /** @type {any} */ (err).statusCode = res.statusCode;
        reject(err);
        return;
      }
      resolve(socket);
    });
    req.once('timeout', () => {
      req.destroy(Object.assign(new Error('Proxy CONNECT timed out'), { code: 'ETIMEDOUT' }));
    });
    req.once('error', reject);
    req.end();
  });
}

/**
 * GET a URL and hand the response stream to the caller. Follows redirects.
 *
 * @param {string} url
 * @param {{timeoutMs?: number, redirects?: number, env?: NodeJS.ProcessEnv}} [opts]
 * @returns {Promise<import('node:http').IncomingMessage>}
 */
async function openStream(url, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const redirects = opts.redirects ?? MAX_REDIRECTS;
  const env = opts.env ?? process.env;
  const target = new URL(url);

  if (target.protocol !== 'https:') {
    throw new Error(`Refusing to download over ${target.protocol} — https is required: ${url}`);
  }

  /** @type {Record<string, unknown>} */
  const requestOptions = {
    host: target.hostname,
    port: target.port || 443,
    path: `${target.pathname}${target.search}`,
    method: 'GET',
    headers: { 'User-Agent': USER_AGENT, Accept: '*/*' },
    timeout: timeoutMs,
  };

  const proxy = proxyForUrl(url, env);
  if (proxy) {
    // Tunnel first, then run TLS end-to-end over the tunnel, so the proxy
    // never sees plaintext and certificate validation still targets GitHub.
    requestOptions.socket = await connectThroughProxy(proxy, target, timeoutMs);
    requestOptions.agent = false;
    requestOptions.servername = target.hostname;
  }

  const res = await new Promise((resolve, reject) => {
    const req = https.request(requestOptions, resolve);
    req.once('timeout', () => {
      req.destroy(Object.assign(new Error(`Request to ${url} timed out`), { code: 'ETIMEDOUT' }));
    });
    req.once('error', reject);
    req.end();
  });

  const status = res.statusCode ?? 0;
  if (status >= 300 && status < 400 && res.headers.location) {
    res.resume();
    if (redirects <= 0) throw new Error(`Too many redirects fetching ${url}`);
    const next = new URL(res.headers.location, url).toString();
    return openStream(next, { ...opts, redirects: redirects - 1, env });
  }
  if (status !== 200) {
    res.resume();
    const err = new Error(`HTTP ${status} fetching ${url}`);
    /** @type {any} */ (err).statusCode = status;
    throw err;
  }
  return res;
}

/**
 * Download a URL fully into memory. Only used for the small checksum asset.
 *
 * @param {string} url
 * @param {{timeoutMs?: number, env?: NodeJS.ProcessEnv}} [opts]
 * @returns {Promise<string>}
 */
async function fetchText(url, opts = {}) {
  const res = await openStream(url, opts);
  const chunks = [];
  for await (const chunk of res) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

module.exports = { openStream, fetchText, proxyForUrl, USER_AGENT, DEFAULT_TIMEOUT_MS };
