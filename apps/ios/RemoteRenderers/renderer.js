import RFB from '@novnc/novnc';
import { RemoteViewport } from './viewport.js';
const KeyTable = {XK_Control_L:0xffe3,XK_Escape:0xff1b,XK_Tab:0xff09,XK_Left:0xff51,XK_Up:0xff52,XK_Right:0xff53,XK_Down:0xff54,XK_BackSpace:0xff08,XK_Return:0xff0d};
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';

let rendererGeneration = null;
const post = (type, data = {}, generation = rendererGeneration) => window.webkit.messageHandlers.remote.postMessage({type, generation, ...data});
const surface = document.getElementById('surface');
const toolbar = document.getElementById('tools');
const keyboard = document.getElementById('keyboard');
const encode = bytes => {
  let value = '';
  for (let i = 0; i < bytes.length; i += 8192) value += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(value);
};
const decode = value => Uint8Array.from(atob(value), char => char.charCodeAt(0));
let rfb, viewport, terminal, fit, channel, resizeObserver, controlling = false, ctrl = false;
function send(bytes, generation = rendererGeneration) {
  if (bytes.length > 65536) { post('failure', {message:'Input is limited to 64 KiB at a time.'}, generation); return; }
  post('bytes', {data: encode(bytes)}, generation);
}
function button(label, action) {
  const element = document.createElement('button');
  element.textContent = label; element.type = 'button'; element.onclick = action;
  toolbar.appendChild(element); return element;
}
class NativeChannel {
  constructor(generation) {
    this.generation = generation; this.readyState = 0; this.protocol = ''; this.binaryType = 'arraybuffer';
    this.onerror = this.onmessage = this.onopen = this.onclose = null;
  }
  send(value) { send(new Uint8Array(value), this.generation); }
  close() { this.readyState = 3; post('close', {}, this.generation); }
}
function key(symbol, text) {
  if (terminal) { terminal.input(ctrl ? String.fromCharCode(text.charCodeAt(0) & 31) : text); }
  else if (rfb && controlling) {
    if (ctrl) rfb.sendKey(KeyTable.XK_Control_L, 'ControlLeft', true);
    rfb.sendKey(symbol);
    if (ctrl) rfb.sendKey(KeyTable.XK_Control_L, 'ControlLeft', false);
  }
  ctrl = false; document.getElementById('ctrl')?.classList.remove('selected');
}
function textInput(text) {
  for (const character of text) {
    const point = character.codePointAt(0);
    if (character === '\n') { key(KeyTable.XK_Return, '\r'); continue; }
    key(point <= 255 ? point : 0x01000000 | point, character);
  }
}
function setupTools(kind) {
  toolbar.replaceChildren();
  button('Keyboard', () => {
    if (kind === 'terminal') terminal.focus();
    else { keyboard.hidden = !keyboard.hidden; if (!keyboard.hidden) keyboard.focus(); }
  });
  button('Esc', () => key(KeyTable.XK_Escape, '\x1b'));
  button('Tab', () => key(KeyTable.XK_Tab, '\t'));
  const control = button('Ctrl', () => { ctrl = !ctrl; control.classList.toggle('selected', ctrl); }); control.id = 'ctrl';
  for (const [label, symbol, text] of [['←',KeyTable.XK_Left,'\x1b[D'],['↓',KeyTable.XK_Down,'\x1b[B'],['↑',KeyTable.XK_Up,'\x1b[A'],['→',KeyTable.XK_Right,'\x1b[C']]) button(label, () => key(symbol, text));
  if (kind === 'display') {
    const zoom = button('1:1', () => viewport.toggleFit());
    viewport.onChange = () => { zoom.textContent = viewport.fitting ? '1:1' : 'Fit'; };
    const pan = button('Pan', () => { viewport.pan = !viewport.pan; pan.classList.toggle('selected', viewport.pan); });
  }
}
keyboard.addEventListener('input', event => {
  if (event.isComposing) return;
  textInput(keyboard.value); keyboard.value = '';
});
keyboard.addEventListener('beforeinput', event => {
  if (event.inputType === 'deleteContentBackward' && !event.isComposing) { event.preventDefault(); key(KeyTable.XK_BackSpace, '\x7f'); }
  if (['insertLineBreak','insertParagraph'].includes(event.inputType)) { event.preventDefault(); key(KeyTable.XK_Return, '\r'); }
});
window.remote = {
  setup({kind,generation}) {
    rendererGeneration = generation;
    const notify = (type, data = {}) => post(type, data, generation);
    resizeObserver?.disconnect(); viewport?.dispose(); viewport = null; rfb?.disconnect(); terminal?.dispose(); rfb = terminal = null; keyboard.hidden = true;
    surface.replaceChildren(); controlling = false; ctrl = false;
    if (kind === 'display') {
      const target = document.createElement('div'); surface.appendChild(target);
      channel = new NativeChannel(generation); rfb = new RFB(target, channel);
      rfb.viewOnly = true; rfb.scaleViewport = true; rfb.clipViewport = false; rfb.resizeSession = false;
      viewport = new RemoteViewport(surface, target, rfb);
      rfb.addEventListener('connect', () => notify('connected'));
      rfb.addEventListener('disconnect', () => notify('closed'));
      rfb.addEventListener('securityfailure', () => notify('failure', {message: 'The guest desktop rejected the connection.'}));
    } else {
      terminal = new Terminal({cursorBlink:true,fontSize:15,scrollback:3000,theme:{background:'#101419'}});
      fit = new FitAddon(); terminal.loadAddon(fit); terminal.open(surface);
      terminal.onData(value => send(new TextEncoder().encode(value), generation));
      terminal.onBinary(value => send(Uint8Array.from(value, character => character.charCodeAt(0)), generation));
      terminal.onResize(({cols,rows}) => notify('resize', {cols,rows}));
      resizeObserver = new ResizeObserver(() => { if (terminal) fit.fit(); }); resizeObserver.observe(surface);
      fit.fit();
    }
    setupTools(kind); notify('ready');
  },
  opened() { if (channel && rfb) { channel.readyState = 1; channel.onopen?.({}); } else { fit?.fit(); if (terminal) post('resize', {cols:terminal.cols,rows:terminal.rows}); post('connected'); } },
  bytes(data) {
    const bytes = decode(data);
    if (rfb) channel.onmessage?.({data:bytes.buffer});
    else if (terminal) return new Promise(resolve => terminal.write(bytes, resolve));
  },
  closed() { if (channel && rfb) { channel.readyState = 3; channel.onclose?.({code:1006,reason:'Disconnected'}); } },
  control(value) { controlling = value; if (rfb) rfb.viewOnly = !value; keyboard.disabled = !value; },
  paste(text) { if (terminal) terminal.paste(text); else if (controlling) rfb?.clipboardPasteFrom(text); },
};
post('loaded');
