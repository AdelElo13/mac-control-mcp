'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { proxyForUrl } = require('../lib/download');
const { openStream } = require('../lib/download');

const URL_UNDER_TEST = 'https://github.com/AdelElo13/mac-control-mcp/releases/download/v0.8.3/x.tar.gz';

test('proxyForUrl honours HTTPS_PROXY', () => {
  assert.equal(proxyForUrl(URL_UNDER_TEST, { HTTPS_PROXY: 'http://proxy:8080' }), 'http://proxy:8080');
  assert.equal(proxyForUrl(URL_UNDER_TEST, { https_proxy: 'http://proxy:8080' }), 'http://proxy:8080');
  assert.equal(proxyForUrl(URL_UNDER_TEST, { ALL_PROXY: 'http://proxy:8080' }), 'http://proxy:8080');
});

test('proxyForUrl returns null when no proxy is configured', () => {
  assert.equal(proxyForUrl(URL_UNDER_TEST, {}), null);
  assert.equal(proxyForUrl(URL_UNDER_TEST, { HTTPS_PROXY: '  ' }), null);
  // HTTP_PROXY must not be applied to an https target.
  assert.equal(proxyForUrl(URL_UNDER_TEST, { HTTP_PROXY: 'http://proxy:8080' }), null);
});

test('proxyForUrl respects NO_PROXY exclusions', () => {
  const env = { HTTPS_PROXY: 'http://proxy:8080' };
  assert.equal(proxyForUrl(URL_UNDER_TEST, { ...env, NO_PROXY: '*' }), null);
  assert.equal(proxyForUrl(URL_UNDER_TEST, { ...env, NO_PROXY: 'github.com' }), null);
  assert.equal(proxyForUrl(URL_UNDER_TEST, { ...env, no_proxy: '.github.com' }), null);
  assert.equal(
    proxyForUrl(URL_UNDER_TEST, { ...env, NO_PROXY: 'example.com' }),
    'http://proxy:8080',
  );
  // Suffix matching must not treat "hub.com" as covering "github.com".
  assert.equal(proxyForUrl(URL_UNDER_TEST, { ...env, NO_PROXY: 'hub.com' }), 'http://proxy:8080');
});

test('openStream refuses plaintext http downloads', async () => {
  await assert.rejects(
    () => openStream('http://github.com/whatever'),
    /https is required/,
  );
});
