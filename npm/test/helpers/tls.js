'use strict';

/**
 * Self-signed cert for localhost, shared by the proxy and postinstall e2e
 * tests. openssl ships with macOS; if it is missing or too old for -addext
 * the callers skip rather than fail spuriously.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

/**
 * @returns {{key: string, cert: string}|null}
 */
function makeSelfSignedCert() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcmcp-tls-'));
  const keyPath = path.join(dir, 'key.pem');
  const certPath = path.join(dir, 'cert.pem');
  const res = spawnSync(
    '/usr/bin/openssl',
    [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', keyPath, '-out', certPath,
      '-days', '1', '-subj', '/CN=localhost',
      '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
    ],
    { encoding: 'utf8' },
  );
  if (res.status !== 0) {
    fs.rmSync(dir, { recursive: true, force: true });
    return null;
  }
  const out = {
    key: fs.readFileSync(keyPath, 'utf8'),
    cert: fs.readFileSync(certPath, 'utf8'),
  };
  fs.rmSync(dir, { recursive: true, force: true });
  return out;
}

module.exports = { makeSelfSignedCert };
