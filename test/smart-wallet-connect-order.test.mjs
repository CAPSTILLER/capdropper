/**
 * Regression: Coinbase Smart Wallet providers require eth_requestAccounts
 * before eth_chainId / wallet_switchEthereumChain / eth_call / etc.
 * Run: node test/smart-wallet-connect-order.test.mjs
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');

function createSmartWalletLikeProvider(opts = {}) {
  const methods = [];
  let authorized = !!opts.preAuthorized;
  const accounts = opts.accounts || ['0x1111111111111111111111111111111111111111'];
  const provider = {
    methods,
    async request({ method, params }) {
      methods.push(method);
      if (!authorized && method !== 'eth_requestAccounts' && method !== 'eth_accounts') {
        const err = new Error("Must call 'eth_requestAccounts' before other methods");
        err.code = -32000;
        throw err;
      }
      if (method === 'eth_requestAccounts') {
        authorized = true;
        return accounts;
      }
      if (method === 'eth_accounts') {
        return authorized ? accounts : [];
      }
      if (method === 'eth_chainId') {
        return opts.chainId || '0x1';
      }
      if (method === 'wallet_switchEthereumChain') {
        opts.chainId = (params && params[0] && params[0].chainId) || '0x2105';
        return null;
      }
      if (method === 'wallet_addEthereumChain') {
        return null;
      }
      throw new Error('unexpected method: ' + method);
    }
  };
  return provider;
}

const BASE_CHAIN_ID_HEX = '0x2105';

async function ensureBaseNetwork(provider) {
  const currentChainId = await provider.request({ method: 'eth_chainId' });
  if (currentChainId !== BASE_CHAIN_ID_HEX && parseInt(currentChainId, 16) !== 8453) {
    try {
      await provider.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: BASE_CHAIN_ID_HEX }]
      });
    } catch (err) {
      if (err.code === 4902) {
        await provider.request({
          method: 'wallet_addEthereumChain',
          params: [{ chainId: BASE_CHAIN_ID_HEX, chainName: 'Base Mainnet' }]
        });
      } else {
        throw err;
      }
    }
  }
}

/** Correct connect order used by the app after the fix. */
async function connectSmartWallet(provider) {
  const accounts = await provider.request({ method: 'eth_requestAccounts' });
  if (!accounts || accounts.length === 0) throw new Error('Wallet not connected.');
  await ensureBaseNetwork(provider);
  return accounts[0];
}

/** Buggy order that reproduced Cap's phone error. */
async function connectSmartWalletBuggy(provider) {
  await ensureBaseNetwork(provider);
  const accounts = await provider.request({ method: 'eth_requestAccounts' });
  return accounts[0];
}

async function resumePassive(provider) {
  const accounts = await provider.request({ method: 'eth_accounts' });
  if (!accounts || !accounts[0]) return null;
  return accounts[0];
}

function assertFirstNonPassiveIsRequestAccounts(methods) {
  const first = methods.find((m) => m !== 'eth_accounts');
  assert.equal(
    first,
    'eth_requestAccounts',
    'first non-passive method must be eth_requestAccounts, got: ' + JSON.stringify(methods)
  );
}

function assertHtmlConnectOrder(filePath) {
  const html = fs.readFileSync(filePath, 'utf8');

  function extractFn(name) {
    const start = html.indexOf('async function ' + name + '(');
    assert.ok(start >= 0, name + ' missing in ' + filePath);
    const brace = html.indexOf('{', start);
    let depth = 0;
    for (let i = brace; i < html.length; i++) {
      if (html[i] === '{') depth++;
      else if (html[i] === '}') {
        depth--;
        if (depth === 0) return html.slice(start, i + 1);
      }
    }
    throw new Error('unclosed ' + name);
  }

  for (const name of ['connectWallet', 'getSigner']) {
    const body = extractFn(name);
    const reqIdx = body.indexOf("method: 'eth_requestAccounts'");
    const ensureIdx = body.indexOf('ensureBaseNetwork(');
    assert.ok(reqIdx >= 0, name + ' must call eth_requestAccounts');
    assert.ok(ensureIdx >= 0, name + ' must call ensureBaseNetwork after accounts');
    assert.ok(
      reqIdx < ensureIdx,
      name + ' must call eth_requestAccounts before ensureBaseNetwork'
    );
  }

  const init = extractFn('initWalletFromMemory');
  assert.ok(init.includes("method: 'eth_accounts'"), 'init must use eth_accounts');
  assert.ok(!init.includes('ensureBaseNetwork('), 'init must not switch chain');
  assert.ok(!init.includes("method: 'eth_requestAccounts'"), 'init must not request accounts');
}

async function main() {
  // 1) Correct order succeeds; first active method is eth_requestAccounts
  {
    const p = createSmartWalletLikeProvider({ chainId: '0x1' });
    const addr = await connectSmartWallet(p);
    assert.equal(addr, '0x1111111111111111111111111111111111111111');
    assertFirstNonPassiveIsRequestAccounts(p.methods);
    assert.ok(p.methods.includes('eth_chainId'));
    assert.ok(p.methods.includes('wallet_switchEthereumChain'));
    assert.equal(p.methods[0], 'eth_requestAccounts');
  }

  // 2) Buggy order fails with Cap's exact-class error
  {
    const p = createSmartWalletLikeProvider({ chainId: '0x1' });
    await assert.rejects(
      () => connectSmartWalletBuggy(p),
      (err) => {
        assert.match(String(err.message), /eth_requestAccounts/);
        return true;
      }
    );
    assert.equal(p.methods[0], 'eth_chainId');
  }

  // 3) Passive resume: eth_accounts only, empty stays disconnected, no switch
  {
    const p = createSmartWalletLikeProvider();
    const addr = await resumePassive(p);
    assert.equal(addr, null);
    assert.deepEqual(p.methods, ['eth_accounts']);
  }

  // 4) Passive resume when already authorized does not call requestAccounts
  {
    const p = createSmartWalletLikeProvider({ preAuthorized: true, chainId: '0x2105' });
    const addr = await resumePassive(p);
    assert.ok(addr);
    assert.deepEqual(p.methods, ['eth_accounts']);
  }

  // 5) Source order in both HTML entry points
  assertHtmlConnectOrder(path.join(root, 'index.html'));
  assertHtmlConnectOrder(path.join(root, 'app/index.html'));

  console.log('ok: smart-wallet connect order');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
