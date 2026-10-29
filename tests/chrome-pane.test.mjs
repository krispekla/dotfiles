import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { spawnSync } from 'node:child_process';
import { access, mkdtemp, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import test from 'node:test';
import {
  ActionQueue, Browser, CHROME, KittyRenderer, LatestFrame, TerminalInput,
  keyEvent, kittyFrame, mouseEvent, viewport, webURL,
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

test('Kitty frames transfer a file reference instead of image bytes through the terminal', () => {
  const path = '/tmp/chrome-frame.png';
  const output = kittyFrame(path, viewport(80, 24), 2);
  assert.equal(output, `\x1b[3;1H\x1b_Ga=T,f=100,t=f,i=2,p=1,c=80,r=22,q=0;${Buffer.from(path).toString('base64')}\x1b\\`);
  assert.ok(output.length < 200);
});

test('latest-frame queue drops obsolete frames and can be woken for resize or quit', async () => {
  const frames = new LatestFrame();
  frames.push('old');
  frames.push('new');
  assert.equal(await frames.next(), 'new');
  const pending = frames.next();
  frames.push('next');
  assert.equal(await pending, 'next');
  const quitting = frames.next();
  frames.wake();
  assert.equal(await quitting, null);
});

test('renderer waits for file consumption and backpressure, then skips identical frames', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chrome-render-test-'));
  const input = new EventEmitter();
  const output = new EventEmitter();
  const writes = [];
  output.write = (text) => { writes.push(text); output.emit('write'); return false; };
  try {
    const path = join(directory, 'frame.png');
    const renderer = new KittyRenderer(input, path, output);
    const written = once(output, 'write');
    let completed = false;
    const drawing = renderer.render('aGVsbG8=', viewport(80, 24)).then(() => { completed = true; });
    await written;
    assert.equal(await readFile(path, 'utf8'), 'hello');
    assert.equal((await stat(path)).mode & 0o777, 0o600);
    input.emit('graphics', 'OK', { i: '99' });
    assert.equal(completed, false);
    input.emit('graphics', 'OK', { i: '1' });
    await sleep(0);
    assert.equal(completed, false);
    output.emit('drain');
    await drawing;
    assert.equal(completed, true);
    const count = writes.length;
    await renderer.render('aGVsbG8=', viewport(80, 24));
    assert.equal(writes.length, count);
    output.write = (text) => { writes.push(text); output.emit('write'); return true; };
    const nextWritten = once(output, 'write');
    const next = renderer.render('bmV4dA==', viewport(80, 24));
    await nextWritten;
    input.emit('graphics', 'OK', { i: '2' });
    await next;
    assert.ok(writes.at(-1).includes('a=d,d=I,i=1'));
    assert.equal(input.listenerCount('graphics'), 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('renderer surfaces terminal image loading errors', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chrome-render-error-'));
  const input = new EventEmitter();
  const output = new EventEmitter();
  output.write = () => { output.emit('write'); return true; };
  try {
    const renderer = new KittyRenderer(input, join(directory, 'frame.png'), output);
    const written = once(output, 'write');
    const rejected = assert.rejects(renderer.render('aGVsbG8=', viewport(80, 24)), /ENOENT/);
    await written;
    input.emit('graphics', 'ENOENT: missing file', { i: '1' });
    await rejected;
    assert.equal(input.listenerCount('graphics'), 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('scroll bursts coalesce without crossing ordered keyboard or click actions', async () => {
  const dispatched = [];
  const failures = [];
  const queue = new ActionQueue(async (event) => dispatched.push(event), (error) => failures.push(error));
  let release;
  queue.add(() => new Promise((resolve) => { release = resolve; }));
  const wheel = { type: 'mouseWheel', modifiers: 0, x: 10, y: 20, deltaX: 0, deltaY: 120 };
  for (let i = 0; i < 100; i++) queue.mouse(wheel);
  assert.equal(queue.items.length, 1);
  queue.add(() => dispatched.push('key'));
  queue.mouse({ ...wheel, deltaY: -120 });
  queue.mouse({ type: 'mousePressed', button: 'left', buttons: 1, modifiers: 0 });
  queue.mouse({ type: 'mouseMoved', buttons: 1, modifiers: 0, x: 1 });
  queue.mouse({ type: 'mouseMoved', buttons: 1, modifiers: 0, x: 2 });
  queue.mouse({ type: 'mouseReleased', button: 'left', buttons: 0, modifiers: 0 });
  release();
  await queue.idle;
  assert.equal(dispatched[0].deltaY, 12000);
  assert.equal(dispatched[1], 'key');
  assert.equal(dispatched[2].deltaY, -120);
  assert.equal(dispatched[3].type, 'mousePressed');
  assert.equal(dispatched[4].x, 2);
  assert.equal(dispatched[5].type, 'mouseReleased');
  assert.deepEqual(failures, []);
  await queue.close();
});

test('input errors stop queued actions instead of silently losing input', async () => {
  const failures = [];
  const queue = new ActionQueue(async () => { throw new Error('input failed'); }, (error) => failures.push(error));
  queue.mouse({ type: 'mousePressed' });
  queue.add(() => assert.fail('must not run'));
  await queue.idle;
  assert.equal(failures[0].message, 'input failed');
  assert.equal(queue.closed, true);
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
    ['focus', false], ['focus', true], ['graphics', 'OK', { i: '1' }],
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
    const streamErrors = [];
    browser.on('Page.screencastFrame', (frame) => {
      browser.send('Page.screencastFrameAck', { sessionId: frame.sessionId })
        .catch((error) => { if (!browser.closed) streamErrors.push(error); });
    });
    const first = once(browser, 'Page.screencastFrame', { signal: AbortSignal.timeout(5000) });
    await browser.send('Page.startScreencast', { format: 'png', everyNthFrame: 1 });
    const [frame] = await first;
    const png = Buffer.from(frame.data, 'base64');
    assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
    assert.equal(png.readUInt32BE(16), 640);
    assert.equal(png.readUInt32BE(20), 352);
    const frameOfSize = (width, height) => new Promise((resolve, reject) => {
      const receive = (frame) => {
        const header = Buffer.from(frame.data.slice(0, 32), 'base64');
        if (header.readUInt32BE(16) === width && header.readUInt32BE(20) === height) {
          clearTimeout(timer);
          browser.off('Page.screencastFrame', receive);
          resolve();
        }
      };
      const timer = setTimeout(() => {
        browser.off('Page.screencastFrame', receive);
        reject(new Error(`No streamed frame at ${width}x${height}`));
      }, 5000);
      browser.on('Page.screencastFrame', receive);
    });
    const resized = frameOfSize(800, 400);
    await browser.resize(800, 400);
    await resized;
    await browser.send('Page.stopScreencast');
    await browser.resize(640, 352);
    const resumed = frameOfSize(640, 352);
    await browser.send('Page.startScreencast', { format: 'png', everyNthFrame: 1 });
    await resumed;
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
    await browser.send('Page.stopScreencast');
    assert.deepEqual(streamErrors, []);
    await assert.rejects(browser.send('NotARealDomain.invalid'), /wasn't found|not found/);
  } finally {
    if (browser) await browser.close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
  assert.ok(browser.child.exitCode !== null || browser.child.signalCode !== null);
  await assert.rejects(stat(profile), { code: 'ENOENT' });
});
