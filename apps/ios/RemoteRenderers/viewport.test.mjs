import {test} from 'node:test';
import assert from 'node:assert/strict';
import {RemoteViewport} from './viewport.js';

class Observer {
  constructor(callback) { this.callback = callback; }
  observe() {}
  disconnect() { this.disconnected = true; }
}
globalThis.ResizeObserver = globalThis.MutationObserver = Observer;

function fixture() {
  const surface = new EventTarget();
  Object.assign(surface, {clientWidth:400, clientHeight:300, scrollLeft:0, scrollTop:0,
    getBoundingClientRect:() => ({left:0, top:0})});
  const target = {style:{}};
  let scale = 1, sent = 0;
  const canvas = {width:1000, height:750, getBoundingClientRect:() => ({
    width:1000 * scale, height:750 * scale, left:-surface.scrollLeft, top:-surface.scrollTop})};
  target.querySelector = () => canvas;
  const rfb = {set scaleViewport(value) {
    assert.equal(value, true);
    scale = Math.min(parseFloat(target.style.width) / canvas.width, parseFloat(target.style.height) / canvas.height);
  }};
  const viewport = new RemoteViewport(surface, target, rfb);
  for (const type of ['gesturestart','gesturemove','gestureend']) surface.addEventListener(type, () => sent++);
  function gesture(type, kind, extra = {}) {
    const event = new Event(type, {cancelable:true});
    event.detail = {type:kind, clientX:200, clientY:150, magnitudeX:100, magnitudeY:0, ...extra};
    surface.dispatchEvent(event);
    return event;
  }
  return {viewport, surface, target, canvas, gesture, scale:() => scale, sent:() => sent};
}

test('pinch scales the local viewport around the fingers without forwarding any phase', () => {
  const f = fixture();
  assert.equal(f.scale(), 0.4);
  f.gesture('gesturestart', 'pinch');
  f.gesture('gesturemove', 'pinch', {magnitudeX:200});
  f.gesture('gestureend', 'pinch', {magnitudeX:200});
  assert.equal(f.scale(), 0.8);
  assert.equal(f.surface.scrollLeft, 200);
  assert.equal(f.surface.scrollTop, 150);
  assert.equal((200 + f.surface.scrollLeft) / f.scale(), 500);
  assert.equal((150 + f.surface.scrollTop) / f.scale(), 375);
  assert.equal(f.sent(), 0);
  assert.equal(f.viewport.fitting, false);
  assert.equal(f.viewport.pinch, null);
});

test('pinch is bounded, Fit responds to rotation, and 1:1 keeps guest pixel size', () => {
  const f = fixture();
  f.gesture('gesturestart', 'pinch');
  f.gesture('gesturemove', 'pinch', {magnitudeX:10000});
  assert.equal(f.scale(), 4);
  f.gesture('gesturemove', 'pinch', {magnitudeX:0});
  assert.equal(f.scale(), 0.4);
  f.viewport.fit();
  f.surface.clientWidth = 300; f.surface.clientHeight = 400;
  f.viewport.resize.callback();
  assert.equal(f.scale(), 0.3);
  f.viewport.toggleFit();
  assert.equal(f.scale(), 1);
  f.viewport.toggleFit();
  assert.equal(f.scale(), 0.3);
  assert.equal(f.surface.scrollLeft, 0);
});

test('one-finger mouse and two-finger scroll reach noVNC, Pan stays local in read-only viewing', () => {
  const f = fixture();
  f.gesture('gesturestart', 'drag');
  f.gesture('gesturemove', 'twodrag');
  assert.equal(f.sent(), 2);
  f.viewport.setScale(1); f.viewport.pan = true;
  f.gesture('gesturestart', 'drag');
  f.gesture('gesturemove', 'drag', {clientX:150, clientY:120});
  f.gesture('gestureend', 'drag');
  assert.equal(f.surface.scrollLeft, 50);
  assert.equal(f.surface.scrollTop, 30);
  assert.equal(f.sent(), 2);
  assert.equal(f.viewport.drag, null);
});

test('replacement disposes gesture handlers and framebuffer resize preserves manual zoom', () => {
  const f = fixture();
  f.viewport.setScale(2);
  f.canvas.width = 1200; f.canvas.height = 900;
  f.viewport.dimensions.callback();
  assert.equal(f.target.style.width, '2400px');
  assert.equal(f.scale(), 2);
  f.viewport.dispose();
  f.gesture('gesturestart', 'pinch');
  assert.equal(f.sent(), 1);
  assert.equal(f.viewport.resize.disconnected, true);
  assert.equal(f.viewport.dimensions.disconnected, true);
});
