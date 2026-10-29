#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { EventEmitter, once } from 'node:events';
import { existsSync, realpathSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PassThrough } from 'node:stream';
import { StringDecoder } from 'node:string_decoder';
import { emitKeypressEvents } from 'node:readline';
import { pathToFileURL } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

export const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

export function webURL(value) {
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol)) {
    throw new Error('Only http:// and https:// URLs are supported.');
  }
  return url.href;
}

export class Browser extends EventEmitter {
  pending = new Map();
  sequence = 0;
  incoming = '';
  diagnostics = '';
  closed = false;

  static async launch() {
    const browser = new Browser();
    browser.profile = await mkdtemp(join(tmpdir(), 'herdr-chrome-'));
    try {
      browser.child = spawn(process.env.CHROME_BIN || CHROME, [
        '--headless=new', '--remote-debugging-pipe',
        `--user-data-dir=${browser.profile}`,
        '--no-first-run', '--no-default-browser-check', '--disable-background-networking', 'about:blank',
      ], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
      browser.exited = new Promise((resolve) => {
        browser.child.once('close', resolve);
      });
      browser.child.stderr.setEncoding('utf8');
      browser.child.stderr.on('data', (text) => {
        browser.diagnostics = (browser.diagnostics + text).slice(-4096);
      });
      const decoder = new StringDecoder('utf8');
      browser.child.stdio[4].on('data', (data) => browser.receive(decoder.write(data)));
      const disconnected = (error) => {
        browser.closed = true;
        for (const { reject, timer } of browser.pending.values()) {
          clearTimeout(timer);
          reject(error);
        }
        browser.pending.clear();
        browser.emit('disconnected', error);
      };
      browser.child.once('error', disconnected);
      browser.child.stdio[3].on('error', disconnected);
      browser.child.once('exit', (code, signal) => disconnected(
        new Error(`Chrome exited (${signal || code}). ${browser.diagnostics.trim()}`),
      ));
      await browser.request('Browser.getVersion');
      const { targetId } = await browser.request('Target.createTarget', { url: 'about:blank' });
      const { sessionId } = await browser.request('Target.attachToTarget', { targetId, flatten: true });
      browser.session = sessionId;
      await browser.send('Page.enable');
      await browser.request('Browser.setDownloadBehavior', { behavior: 'deny' });
      return browser;
    } catch (error) {
      await browser.close();
      throw error;
    }
  }

  receive(text) {
    this.incoming += text;
    let end;
    while ((end = this.incoming.indexOf('\0')) !== -1) {
      const message = JSON.parse(this.incoming.slice(0, end));
      this.incoming = this.incoming.slice(end + 1);
      if (message.id) {
        const waiting = this.pending.get(message.id);
        if (!waiting) continue;
        this.pending.delete(message.id);
        clearTimeout(waiting.timer);
        if (message.error) waiting.reject(new Error(message.error.message));
        else waiting.resolve(message.result);
      } else if (message.sessionId === this.session) {
        this.emit(message.method, message.params);
      }
    }
  }

  request(method, params = {}, sessionId) {
    if (this.closed) return Promise.reject(new Error('Chrome is no longer running.'));
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Chrome timed out: ${method}`));
      }, 10000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
    });
  }

  send(method, params = {}) {
    return this.request(method, params, this.session);
  }

  async navigate(value) {
    const result = await this.send('Page.navigate', { url: webURL(value) });
    if (result.errorText) throw new Error(`Navigation failed: ${result.errorText}`);
  }

  resize(width, height) {
    return this.send('Emulation.setDeviceMetricsOverride', {
      width, height, deviceScaleFactor: 1, mobile: false,
    });
  }

  async close() {
    if (this.child && this.child.exitCode === null && this.child.signalCode === null) {
      this.child.kill('SIGTERM');
      const timer = setTimeout(() => this.child.kill('SIGKILL'), 3000);
      await this.exited;
      clearTimeout(timer);
    }
    if (this.profile) await rm(this.profile, { recursive: true, force: true });
  }
}

export function viewport(columns, rows, cell = { width: 8, height: 16 }) {
  const contentRows = Math.max(1, rows - 2);
  return {
    columns, rows: contentRows,
    width: columns * cell.width, height: contentRows * cell.height,
    cell,
  };
}

export function kittyFrame(path, view, id) {
  const encoded = Buffer.from(path).toString('base64');
  return `\x1b[3;1H\x1b_Ga=T,f=100,t=f,i=${id},p=1,c=${view.columns},r=${view.rows},q=0;${encoded}\x1b\\`;
}

export class LatestFrame {
  frame = null;
  waiter = null;

  push(frame) {
    this.frame = frame;
    this.wake();
  }

  wake() {
    this.waiter?.();
    this.waiter = null;
  }

  async next() {
    if (!this.frame) await new Promise((resolve) => { this.waiter = resolve; });
    const frame = this.frame;
    this.frame = null;
    return frame;
  }
}

export class KittyRenderer {
  previous = 0;

  constructor(input, path, output = process.stdout) {
    this.input = input;
    this.path = path;
    this.output = output;
  }

  async render(png, view) {
    if (png === this.png && view.columns === this.columns && view.rows === this.rows) return;
    const id = this.previous === 1 ? 2 : 1;
    // The terminal must consume the file before it can be overwritten by the next frame.
    await writeFile(this.path, Buffer.from(png, 'base64'), { mode: 0o600 });
    let cleanup;
    const acknowledged = new Promise((resolve, reject) => {
      const receive = (reply, fields) => {
        if (fields.i !== String(id)) return;
        cleanup();
        if (reply === 'OK') resolve();
        else reject(new Error(`Terminal graphics failed: ${reply}`));
      };
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error('No Kitty graphics acknowledgement. Use Ghostty and enable herdr terminal.kitty_graphics.'));
      }, 5000);
      cleanup = () => { clearTimeout(timer); this.input.off('graphics', receive); };
      this.input.on('graphics', receive);
    });
    const abort = new AbortController();
    try {
      const drained = this.output.write(kittyFrame(this.path, view, id))
        ? Promise.resolve() : once(this.output, 'drain', { signal: abort.signal });
      await Promise.all([acknowledged, drained]);
    } finally {
      cleanup();
      abort.abort();
    }
    if (this.previous) this.output.write(`\x1b_Ga=d,d=I,i=${this.previous},q=2\x1b\\`);
    this.previous = id;
    this.png = png;
    this.columns = view.columns;
    this.rows = view.rows;
  }
}

export class ActionQueue {
  items = [];
  busy = false;
  closed = false;
  idle = Promise.resolve();

  constructor(dispatchMouse, fail) {
    this.dispatchMouse = dispatchMouse;
    this.fail = fail;
  }

  add(action) {
    if (this.closed) return;
    this.items.push({ action });
    this.start();
  }

  mouse(event) {
    if (this.closed) return;
    const tail = this.items.at(-1);
    if (tail?.mouse?.type === event.type && tail.mouse.modifiers === event.modifiers
        && tail.mouse.buttons === event.buttons
        && ['mouseMoved', 'mouseWheel'].includes(event.type)) {
      tail.mouse = event.type === 'mouseWheel'
        ? { ...event, deltaX: tail.mouse.deltaX + event.deltaX, deltaY: tail.mouse.deltaY + event.deltaY }
        : event;
    } else {
      const entry = { mouse: event };
      entry.action = () => this.dispatchMouse(entry.mouse);
      this.items.push(entry);
    }
    this.start();
  }

  start() {
    if (!this.busy) this.idle = this.drain();
  }

  async drain() {
    this.busy = true;
    try {
      while (!this.closed && this.items.length) await this.items.shift().action();
    } catch (error) {
      this.closed = true;
      this.items.length = 0;
      this.fail(error);
    } finally {
      this.busy = false;
    }
  }

  async close() {
    this.closed = true;
    this.items.length = 0;
    await this.idle;
  }
}

export function mouseEvent(button, column, row, released, view) {
  if (row <= 2 || row > view.rows + 2 || column < 1 || column > view.columns) return null;
  const modifiers = (button & 4 ? 8 : 0) | (button & 8 ? 1 : 0) | (button & 16 ? 2 : 0);
  const event = {
    x: Math.min(view.width - 1, (column - 0.5) * view.cell.width),
    y: Math.min(view.height - 1, (row - 2.5) * view.cell.height),
    modifiers,
  };
  if (button & 64) {
    return { ...event, type: 'mouseWheel', deltaX: 0, deltaY: button & 1 ? 120 : -120 };
  }
  const which = button & 3;
  return {
    ...event,
    type: button & 32 ? 'mouseMoved' : released ? 'mouseReleased' : 'mousePressed',
    button: ['left', 'middle', 'right', 'none'][which],
    buttons: released ? 0 : [1, 4, 2, 0][which],
    ...(button & 32 ? {} : { clickCount: 1 }),
  };
}

const KEYS = {
  return: ['Enter', 'Enter', 13], tab: ['Tab', 'Tab', 9],
  backspace: ['Backspace', 'Backspace', 8], delete: ['Delete', 'Delete', 46],
  escape: ['Escape', 'Escape', 27], up: ['ArrowUp', 'ArrowUp', 38],
  down: ['ArrowDown', 'ArrowDown', 40], left: ['ArrowLeft', 'ArrowLeft', 37],
  right: ['ArrowRight', 'ArrowRight', 39], home: ['Home', 'Home', 36],
  end: ['End', 'End', 35], pageup: ['PageUp', 'PageUp', 33],
  pagedown: ['PageDown', 'PageDown', 34], space: [' ', 'Space', 32],
};

export function keyEvent(text, key) {
  const modifiers = (key.meta ? 1 : 0) | (key.ctrl ? 2 : 0) | (key.shift ? 8 : 0);
  if (!key.ctrl && !key.meta && text && !/[\x00-\x1f\x7f]/.test(text)) {
    return { text };
  }
  let entry = KEYS[key.name];
  if (!entry && /^[a-z]$/.test(key.name || '')) {
    entry = [key.name, `Key${key.name.toUpperCase()}`, key.name.toUpperCase().charCodeAt(0)];
  }
  if (!entry) return null;
  return {
    key: entry[0], code: entry[1], windowsVirtualKeyCode: entry[2], modifiers,
    ...(key.name === 'return' ? { text: '\r' } : {}),
    ...(key.ctrl && key.name === 'a' ? { commands: ['selectAll'] } : {}),
  };
}

// Keep mouse reports, terminal replies and bracketed paste out of the key decoder.
export class TerminalInput extends EventEmitter {
  pending = '';
  paste = null;
  keys = new PassThrough();
  decoder = new StringDecoder('utf8');

  constructor() {
    super();
    emitKeypressEvents(this.keys);
    this.keys.on('keypress', (text, key) => this.emit('key', text, key));
  }

  write(data) {
    clearTimeout(this.escapeTimer);
    this.pending += typeof data === 'string' ? data : this.decoder.write(data);
    while (this.pending) {
      if (this.paste !== null) {
        const end = this.pending.indexOf('\x1b[201~');
        if (end === -1) {
          // Keep the possible split terminator until the next chunk.
          const keep = Math.min(5, this.pending.length);
          this.paste += this.pending.slice(0, -keep);
          this.pending = this.pending.slice(-keep);
          return;
        }
        this.emit('paste', this.paste + this.pending.slice(0, end));
        this.pending = this.pending.slice(end + 6);
        this.paste = null;
        continue;
      }
      if (this.pending.startsWith('\x1b[200~')) {
        this.paste = '';
        this.pending = this.pending.slice(6);
        continue;
      }
      const mouse = this.pending.match(/^\x1b\[<(\d+);(\d+);(\d+)([mM])/);
      const geometry = this.pending.match(/^\x1b\[6;(\d+);(\d+)t/);
      const graphics = this.pending.match(/^\x1b_G([^;]*);([^\x1b]*)\x1b\\/);
      const focus = this.pending.match(/^\x1b\[([IO])/);
      if (mouse) this.emit('mouse', +mouse[1], +mouse[2], +mouse[3], mouse[4] === 'm');
      else if (geometry) this.emit('geometry', { height: +geometry[1], width: +geometry[2] });
      else if (graphics) {
        this.emit('graphics', graphics[2], Object.fromEntries(
          graphics[1].split(',').map((field) => field.split('=')),
        ));
      }
      else if (focus) this.emit('focus', focus[1] === 'I');
      const match = mouse || geometry || graphics || focus;
      if (match) {
        this.pending = this.pending.slice(match[0].length);
        continue;
      }
      if (/^\x1b(?:$|\[$|\[<$|\[<[\d;]+$|\[6;[\d;]*$|\[20[01]?~?$|_G[^\x1b]*(?:\x1b)?$)/.test(this.pending)) {
        if (this.pending === '\x1b') {
          this.escapeTimer = setTimeout(() => {
            this.pending = '';
            this.emit('key', undefined, { name: 'escape' });
          }, 40);
        }
        return;
      }
      const character = String.fromCodePoint(this.pending.codePointAt(0));
      this.keys.write(character);
      this.pending = this.pending.slice(character.length);
    }
  }

  close() {
    clearTimeout(this.escapeTimer);
    this.keys.destroy();
  }
}

function plain(text) {
  return String(text).replace(/[\x00-\x1f\x7f-\x9f]/g, '');
}

export async function run(url) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    throw new Error('Run chrome-pane.mjs in an interactive terminal (Ghostty + herdr).');
  }
  webURL(url);
  const browser = await Browser.launch();
  const input = new TerminalInput();
  const frames = new LatestFrame();
  const renderer = new KittyRenderer(input, join(browser.profile, 'terminal-frame.png'));
  let running = true;
  let failure;
  let view;
  let cell = { width: 8, height: 16 };
  let currentURL = url;
  let message = '';
  let address = null;
  let dialog = false;
  let focused = true;
  let graphicsReady = false;
  let streaming = false;
  let lastFrameAt = 0;
  const stop = () => { running = false; frames.wake(); };
  const fail = (error) => { failure = error; stop(); };
  const actions = new ActionQueue(
    (event) => browser.send('Input.dispatchMouseEvent', event), fail,
  );
  const enqueue = (action) => {
    actions.add(action);
  };
  let lastHeader = '';
  const header = () => {
    const width = process.stdout.columns;
    const top = `Chrome (experimental${graphicsReady ? '; graphics OK' : ''}) | Ctrl+O URL | Ctrl+R reload | Ctrl+Q quit`;
    const bottom = address === null ? message || currentURL : `URL: ${address}`;
    const text = `\x1b[1;1H\x1b[2K${top.slice(0, width - 1)}\x1b[2;1H\x1b[2K${plain(bottom).slice(0, width - 1)}`;
    if (text !== lastHeader) { process.stdout.write(text); lastHeader = text; }
  };
  const onData = (data) => input.write(data);
  const onResize = () => { header(); frames.wake(); };
  input.on('geometry', (value) => {
    if (value.width > 0 && value.width <= 100 && value.height > 0 && value.height <= 200) {
      cell = value;
      frames.wake();
    }
  });
  input.on('focus', (value) => { focused = value; frames.wake(); });
  input.on('graphics', (reply) => {
    if (reply !== 'OK') fail(new Error(`Terminal graphics failed: ${reply}`));
    else { graphicsReady = true; header(); }
  });
  input.on('paste', (text) => {
    if (address !== null) { address += plain(text); header(); }
    else enqueue(() => browser.send('Input.insertText', { text }));
  });
  input.on('mouse', (...args) => {
    if (!view || address !== null) return;
    const event = mouseEvent(...args, view);
    if (event) actions.mouse(event);
  });
  input.on('key', (text, key) => {
    if (key.ctrl && ['q', 'c'].includes(key.name)) return stop();
    if (address !== null) {
      if (key.name === 'escape') address = null;
      else if (key.name === 'backspace') address = [...address].slice(0, -1).join('');
      else if (key.ctrl && key.name === 'u') address = '';
      else if (key.name === 'return') {
        const value = address;
        try {
          webURL(value);
          address = null;
          message = '';
          enqueue(() => browser.navigate(value));
        } catch (error) {
          message = error.message;
          address = null;
        }
      } else if (text && !key.ctrl && !key.meta && !/[\x00-\x1f\x7f]/.test(text)) address += text;
      header();
      return;
    }
    if (key.ctrl && key.name === 'o') { address = ''; message = ''; header(); return; }
    if (key.ctrl && key.name === 'r') { enqueue(() => browser.send('Page.reload')); return; }
    if (dialog && ['return', 'escape'].includes(key.name)) {
      enqueue(() => browser.send('Page.handleJavaScriptDialog', { accept: key.name === 'return' }));
      return;
    }
    const event = keyEvent(text, key);
    if (!event) return;
    enqueue(async () => {
      if ('key' in event) {
        await browser.send('Input.dispatchKeyEvent', { type: 'keyDown', ...event });
        const { text: ignored, commands: ignoredCommands, ...up } = event;
        await browser.send('Input.dispatchKeyEvent', { type: 'keyUp', ...up });
      } else await browser.send('Input.insertText', event);
    });
  });
  browser.on('disconnected', (error) => { if (running) fail(error); });
  browser.on('Page.screencastFrame', (frame) => {
    browser.send('Page.screencastFrameAck', { sessionId: frame.sessionId }).catch((error) => {
      if (running) fail(error);
    });
    if (running && focused && !dialog) frames.push(frame.data);
  });
  browser.on('Page.frameNavigated', ({ frame }) => {
    if (!frame.parentId) { currentURL = frame.url; message = ''; header(); }
  });
  browser.on('Page.javascriptDialogOpening', ({ message: text }) => {
    dialog = true;
    frames.wake();
    message = `Dialog: ${text} (Enter accepts, Esc dismisses; prompt text is not supported)`;
    header();
  });
  browser.on('Page.javascriptDialogClosed', () => {
    dialog = false;
    message = '';
    header();
    frames.wake();
  });
  browser.on('Page.windowOpen', () => { message = 'Popup requested: use normal Chrome for popup windows.'; header(); });
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  process.on('SIGHUP', stop);
  const wasRaw = process.stdin.isRaw;
  try {
    process.stdin.setRawMode(true);
    process.stdin.on('data', onData);
    process.stdout.on('resize', onResize);
    process.stdin.resume();
    process.stdout.write('\x1b[?1049h\x1b[?25l\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b[16t');
    header();
    await browser.navigate(url);
    while (running) {
      const next = viewport(process.stdout.columns, process.stdout.rows, cell);
      if (!view || next.width !== view.width || next.height !== view.height) {
        frames.frame = null;
        await browser.resize(next.width, next.height);
        view = next;
      }
      if ((!focused || dialog) && streaming) {
        await browser.send('Page.stopScreencast');
        streaming = false;
        frames.frame = null;
      } else if (focused && !dialog && !streaming) {
        await browser.send('Page.startScreencast', { format: 'png', everyNthFrame: 1 });
        streaming = true;
      }
      let png = await frames.next();
      if (!running) break;
      if (!png || !focused || dialog) continue;
      const delay = 1000 / 30 - (performance.now() - lastFrameAt);
      if (delay > 0) await sleep(delay);
      if (!running || !focused || dialog) continue;
      if (frames.frame) {
        png = frames.frame;
        frames.frame = null;
      }
      // Discard a frame from the old viewport while Chrome is applying a resize.
      const dimensions = Buffer.from(png.slice(0, 32), 'base64');
      if (dimensions.readUInt32BE(16) !== view.width || dimensions.readUInt32BE(20) !== view.height) continue;
      await renderer.render(png, view);
      lastFrameAt = performance.now();
    }
  } finally {
    running = false;
    process.stdin.off('data', onData);
    process.stdout.off('resize', onResize);
    process.stdin.setRawMode(wasRaw || false);
    process.stdin.pause();
    input.close();
    process.stdout.write('\x1b_Ga=d,d=I,i=1,q=2\x1b\\\x1b_Ga=d,d=I,i=2,q=2\x1b\\'
      + '\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1002l\x1b[?25h\x1b[?1049l');
    for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(signal, stop);
    await actions.close();
    await browser.close();
  }
  if (failure) throw failure;
}

if (process.argv[1] && existsSync(process.argv[1])
    && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  if (process.argv.includes('--help')) {
    console.log('Usage: chrome-pane.mjs <http(s)://url>\nRequires Node.js 22+, Google Chrome, and a Kitty-graphics terminal.\nCtrl+O: URL | Ctrl+R: reload | Ctrl+Q / Ctrl+C: quit\nMouse: click, drag, scroll. Paste uses terminal bracketed paste.');
  } else {
    run(process.argv[2] || 'http://localhost:8000/').catch((error) => {
      console.error(`chrome-pane: ${error.message}`);
      process.exitCode = 1;
    });
  }
}
