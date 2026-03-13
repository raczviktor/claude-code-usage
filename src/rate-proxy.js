#!/usr/bin/env node
// rate-proxy.js – Transparent reverse proxy for Claude Code
// Forwards requests to api.anthropic.com, extracts rate limit headers
// Writes rate limit data to .usage_cache for statusline.sh
//
// Usage: node rate-proxy.js
// Then set ANTHROPIC_BASE_URL=http://127.0.0.1:8087 in Claude Code settings

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

const PORT = process.env.RATE_PROXY_PORT || 8087;
const TARGET = 'api.anthropic.com';
const CACHE_FILE = path.join(process.env.HOME || process.env.USERPROFILE, '.local', 'bin', '.usage_cache');

const server = http.createServer((req, res) => {
  // Forward request to api.anthropic.com
  const options = {
    hostname: TARGET,
    port: 443,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, host: TARGET },
  };

  const proxyReq = https.request(options, (proxyRes) => {
    // Extract rate limit headers
    extractRateLimits(proxyRes.headers);

    // Forward response
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res, { end: true });
  });

  proxyReq.on('error', (err) => {
    console.error(`[rate-proxy] Error: ${err.message}`);
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ type: 'error', error: { type: 'proxy_error', message: err.message } }));
  });

  req.pipe(proxyReq, { end: true });
});

function extractRateLimits(headers) {
  const prefix = 'anthropic-ratelimit-';
  const vals = {};
  for (const [key, value] of Object.entries(headers)) {
    const lower = key.toLowerCase();
    if (lower.startsWith(prefix)) {
      const name = lower.slice(prefix.length);
      vals[name] = value;
    }
  }

  // Only write if we got rate limit data
  if (vals['unified-5h-utilization'] || vals['unified-7d-utilization']) {
    const cache = [
      `TIMESTAMP=${Math.floor(Date.now() / 1000)}`,
      `STATUS=${vals['unified-status'] || '?'}`,
      `STATUS_5H=${vals['unified-5h-status'] || '?'}`,
      `UTIL_5H=${vals['unified-5h-utilization'] || '?'}`,
      `RESET_5H=${vals['unified-5h-reset'] || '0'}`,
      `STATUS_7D=${vals['unified-7d-status'] || '?'}`,
      `UTIL_7D=${vals['unified-7d-utilization'] || '?'}`,
      `RESET_7D=${vals['unified-7d-reset'] || '0'}`,
    ].join('\n') + '\n';

    fs.writeFile(CACHE_FILE, cache, (err) => {
      if (err) console.error(`[rate-proxy] Cache write error: ${err.message}`);
    });
  }
}

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[rate-proxy] Listening on http://127.0.0.1:${PORT} → https://${TARGET}`);
  console.log(`[rate-proxy] Cache: ${CACHE_FILE}`);
});
