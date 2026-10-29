import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawnSync } from 'node:child_process';
import { access, mkdtemp, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import test from 'node:test';
import {
  Browser, CHROME, TerminalInput, keyEvent, kittyFrame, mouseEvent, viewport, webURL,
} from '../herdr/scripts/chrome-pane.mjs';

test('only web navigation is accepted', () => {
  assert.equal(webURL('http://localhost:8012'), 'http://localhost:8012/');
  for (const value of ['file:///etc/hosts', 'javascript:alert(1)', 'not a URL']) {
    assert.throws(() => webURL(value));
  }
});

test('viewport, cell-based mouse coordinates, wheel and drag', () => {
  const view = viewport(80, 24);
  assert.deepEqual([view.width, view.height], [640, 352]);
  assert.equal(mouseEvent(0, 5, 2, false, view), null);
  assert.equal(mouseEvent(0, 81, 3, false, view), null);
  assert.deepEqual(mouseEvent(0, 5, 5, false, view), {
    type: 'mousePressed', x: 36, y: 40, button: 'left', buttons: 1, modifiers: 0, clickCount: 1,
  });
  assert.equal(mouseEvent(0, 5, 5, true, view).buttons, 0);
  assert.equal(mouseEvent(32, 5, 5, false, view).type, 'mouseMoved');
  assert.equal(mouseEvent(64, 5, 5, false, view).deltaY, -120);
  assert.equal(mouseEvent(65, 5, 5, false, view).deltaY, 120);
  assert.equal(mouseEvent(4 | 8 | 16, 5, 5, false, view).modifiers, 11);
});

test('printable input, Unicode, Enter, navigation and modified keys', () => {
  assert.deepEqual(keyEvent('x', { name: 'x' }), { text: 'x' });
  assert.deepEqual(keyEvent('😀', {}), { text: '😀' });
  assert.equal(keyEvent('\r', { name: 'return' }).text, '\r');
  assert.equal(keyEvent('\x1b[A', { name: 'up' }).key, 'ArrowUp');
  assert.equal(keyEvent('\t', { name: 'tab', shift: true }).modifiers, 8);
  assert.deepEqual(keyEvent('\x01', { name: 'a', ctrl: true }), {
    key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, modifiers: 2, commands: ['selectAll'],
  });
  assert.equal(keyEvent('', { name: 'unsupported' }), null);
});

test('Kitty frames are chunked, positioned below the header and bounded to two image IDs', () => {
  const png = 'a'.repeat(9000);
  const output = kittyFrame(png, viewport(80, 24), 2, 1);
  assert.ok(output.startsWith('\x1b[3;1H\x1b_Ga=T,f=100,t=d,i=2,p=1,c=80,r=22,q=1,m=1;'));
  assert.equal((output.match(/\x1b_Gm=/g) || []).length, 2);
  assert.ok(output.includes('\x1b_Gm=0;'));
  assert.ok(output.endsWith('\x1b_Ga=d,d=I,i=1,q=1\x1b\\'));
  assert.ok(kittyFrame('abc', viewport(80, 24), 1, 0).includes('q=0,m=0'));
});

test('terminal decoder handles split mouse, pixel geometry, paste, focus and Unicode', (t) => {
  const input = new TerminalInput();
  t.after(() => input.close());
  const events = [];
  for (const kind of ['mouse', 'geometry', 'paste', 'focus', 'graphics', 'key']) {
    input.on(kind, (...args) => events.push([kind, ...args]));
  }
  input.write('\x1b');
  input.write('[<0;5;');
  input.write('5M\x1b[<0;5;5m\x1b[6;20;10t');
  input.write('\x1b[200~hello \x03😀\x1b[20');
  input.write('1~\x1b[O\x1b[I\x1b_Gi=1;OK\x1b\\');
  input.write(Buffer.from('é😀'));
  assert.deepEqual(events.slice(0, 7), [
    ['mouse', 0, 5, 5, false], ['mouse', 0, 5, 5, true],
    ['geometry', { height: 20, width: 10 }], ['paste', 'hello \x03😀'],
    ['focus', false], ['focus', true], ['graphics', 'OK'],
  ]);
  assert.deepEqual(events.filter(([kind]) => kind === 'key').map(([, text]) => text), ['é', '😀']);
});

test('standalone Escape is delivered without waiting for another key', async (t) => {
  const input = new TerminalInput();
  t.after(() => input.close());
  const next = once(input, 'key');
  input.write('\x1b');
  const [, key] = await next;
  assert.equal(key.name, 'escape');
});

test('launcher validates before opening a tab and shell-quotes the URL', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chrome-launch-test-'));
  try {
    const calls = join(directory, 'calls');
    const fakeHerdr = join(directory, 'herdr');
    await writeFile(fakeHerdr, `#!${process.execPath}
      const fs=require('node:fs');
      fs.appendFileSync(process.env.TEST_CALLS, JSON.stringify(process.argv.slice(2))+'\\n');
      if(process.argv[2]==='tab') console.log(JSON.stringify({result:{root_pane:{pane_id:'wtest:p1'}}}));
    `, { mode: 0o700 });
    const env = {
      ...process.env, HERDR_ENV: '1', HERDR_WORKSPACE_ID: 'wtest',
      HERDR_ACTIVE_WORKSPACE_ID: 'wtest', HERDR_BIN_PATH: fakeHerdr,
      CHROME_BIN: process.execPath, TEST_CALLS: calls,
    };
    const url = "http://localhost:8012/?q=a'b&x=$HOME";
    const launched = spawnSync('sh', ['herdr/scripts/chrome-pane.sh', url], { env, encoding: 'utf8' });
    assert.equal(launched.status, 0, launched.stderr);
    const recorded = (await readFile(calls, 'utf8')).trim().split('\n').map((line) => JSON.parse(line));
    assert.equal(recorded.length, 2);
    assert.equal(recorded[0][0], 'tab');
    assert.deepEqual(recorded[1].slice(0, 3), ['pane', 'run', 'wtest:p1']);
    const parsed = spawnSync('sh', ['-c', `set -- ${recorded[1][3]}; printf '%s\\n' "$@"`], { encoding: 'utf8' });
    assert.equal(parsed.status, 0, parsed.stderr);
    assert.equal(parsed.stdout.trim().split('\n').at(-1), url);
    const invalid = spawnSync('sh', ['herdr/scripts/chrome-pane.sh', 'javascript:alert(1)'], { env, encoding: 'utf8' });
    assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, /Only http/);
    assert.equal((await readFile(calls, 'utf8')).trim().split('\n').length, 2);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('the installed symlink still runs the CLI rather than silently importing it', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chrome-symlink-test-'));
  try {
    const installed = join(directory, 'chrome-pane.mjs');
    await symlink(new URL('../herdr/scripts/chrome-pane.mjs', import.meta.url), installed);
    const result = spawnSync(process.execPath, [installed, 'http://localhost:8012/'], { encoding: 'utf8' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /interactive terminal/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('real Chrome: render, mouse, text, key focus, scrolling, errors and cleanup', async (t) => {
  try {
    await access(process.env.CHROME_BIN || CHROME);
  } catch {
    t.skip('Google Chrome is not installed; set CHROME_BIN to test another installation.');
    return;
  }
  const server = createServer((request, response) => {
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end(`<!doctype html><title>Chrome bridge test</title>
      <body style="height:3000px;background:#18384b;color:white">
      <input id="entry" style="position:absolute;left:20px;top:20px;width:200px;height:40px">
      <button id="button" style="position:absolute;left:20px;top:90px;width:200px;height:40px"
        onclick="this.textContent=String(++window.clicks)">Click me</button>
      <script>window.clicks=0;</script>`);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  let browser;
  let profile;
  try {
    browser = await Browser.launch();
    profile = browser.profile;
    await browser.resize(640, 352);
    await browser.navigate(`http://127.0.0.1:${server.address().port}/`);
    const evaluate = async (expression) => {
      const result = await browser.send('Runtime.evaluate', { expression, returnByValue: true });
      assert.equal(result.exceptionDetails, undefined);
      return result.result.value;
    };
    const waitFor = async (expression) => {
      for (let i = 0; i < 50; i++) {
        if (await evaluate(expression)) return;
        await sleep(20);
      }
      assert.fail(`Chrome did not reach expected state: ${expression}`);
    };
    await waitFor('!!document.querySelector("#entry")');
    const png = Buffer.from(await browser.screenshot(), 'base64');
    assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
    assert.equal(png.readUInt32BE(16), 640);
    assert.equal(png.readUInt32BE(20), 352);
    const view = viewport(80, 24);
    for (const released of [false, true]) {
      await browser.send('Input.dispatchMouseEvent', mouseEvent(0, 5, 5, released, view));
    }
    assert.equal(await evaluate('document.activeElement.id'), 'entry');
    await browser.send('Input.insertText', keyEvent('hello 😀', {}));
    assert.equal(await evaluate('entry.value'), 'hello 😀');
    const selectAll = keyEvent('\x01', { name: 'a', ctrl: true });
    await browser.send('Input.dispatchKeyEvent', { type: 'keyDown', ...selectAll });
    await browser.send('Input.dispatchKeyEvent', { type: 'keyUp', ...selectAll });
    await browser.send('Input.insertText', { text: 'tested' });
    assert.equal(await evaluate('entry.value'), 'tested');
    for (const type of ['keyDown', 'keyUp']) {
      await browser.send('Input.dispatchKeyEvent', { type, ...keyEvent('\t', { name: 'tab' }) });
    }
    assert.equal(await evaluate('document.activeElement.id'), 'button');
    for (const type of ['keyDown', 'keyUp']) {
      await browser.send('Input.dispatchKeyEvent', { type, ...keyEvent('\r', { name: 'return' }) });
    }
    assert.equal(await evaluate('window.clicks'), 1);
    await browser.send('Input.dispatchMouseEvent', mouseEvent(65, 5, 9, false, view));
    await waitFor('window.scrollY > 0');
    await assert.rejects(browser.send('NotARealDomain.invalid'), /wasn't found|not found/);
  } finally {
    if (browser) await browser.close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
  assert.ok(browser.child.exitCode !== null || browser.child.signalCode !== null);
  await assert.rejects(stat(profile), { code: 'ENOENT' });
});
