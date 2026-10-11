// Keep zoom in noVNC's scale calculation so pointer coordinates still map to guest pixels.
export class RemoteViewport {
  constructor(surface, target, rfb) {
    this.surface = surface;
    this.target = target;
    this.rfb = rfb;
    this.fitting = true;
    this.pan = false;
    this.scale = 1;
    this.pinch = null;
    this.drag = null;
    this.onChange = () => {};
    this.events = new AbortController();
    for (const type of ['gesturestart', 'gesturemove', 'gestureend']) {
      surface.addEventListener(type, event => this.gesture(event), {capture:true, signal:this.events.signal});
    }
    this.resize = new ResizeObserver(() => { if (this.fitting) this.fit(); });
    this.resize.observe(surface);
    this.dimensions = new MutationObserver(() => {
      if (!this.fitting) this.setScale(this.scale);
    });
    const canvas = target.querySelector('canvas');
    if (canvas) this.dimensions.observe(canvas, {attributes:true, attributeFilter:['width','height']});
    this.fit();
  }
  dispose() {
    this.events.abort(); this.resize.disconnect(); this.dimensions.disconnect();
  }
  fit() {
    this.fitting = true;
    this.target.style.width = `${this.surface.clientWidth}px`;
    this.target.style.height = `${this.surface.clientHeight}px`;
    this.rfb.scaleViewport = true;
    this.surface.scrollLeft = this.surface.scrollTop = 0;
    this.onChange();
  }
  setScale(scale) {
    const canvas = this.target.querySelector('canvas');
    if (!canvas?.width || !canvas.height || !Number.isFinite(scale) || scale <= 0) return;
    this.scale = scale; this.fitting = false;
    this.target.style.width = `${canvas.width * scale}px`;
    this.target.style.height = `${canvas.height * scale}px`;
    // Public setter updates the canvas AND the inverse mapping for remote input immediately.
    this.rfb.scaleViewport = true;
    this.onChange();
  }
  toggleFit() { if (this.fitting) this.setScale(1); else this.fit(); }
  gesture(event) {
    const detail = event.detail;
    const panning = this.pan && ['drag','longpress'].includes(detail?.type);
    if (detail?.type !== 'pinch' && !panning) return;
    // noVNC maps pinch to guest Ctrl+wheel. Consume all three phases before that handler.
    event.stopImmediatePropagation(); event.preventDefault();
    const canvas = this.target.querySelector('canvas');
    if (!canvas?.width || !canvas.height) return;
    if (panning) {
      if (event.type === 'gesturestart') this.drag = {x:detail.clientX, y:detail.clientY};
      if (event.type === 'gesturemove' && this.drag) {
        this.surface.scrollLeft += this.drag.x - detail.clientX;
        this.surface.scrollTop += this.drag.y - detail.clientY;
        this.drag = {x:detail.clientX, y:detail.clientY};
      }
      if (event.type === 'gestureend') this.drag = null;
      return;
    }
    const distance = Math.hypot(detail.magnitudeX, detail.magnitudeY);
    if (event.type === 'gesturestart') {
      const rect = canvas.getBoundingClientRect();
      const surfaceRect = this.surface.getBoundingClientRect();
      const scale = rect.width / canvas.width;
      this.pinch = distance > 0 && scale > 0 ? {
        distance, scale,
        x:(detail.clientX - rect.left) / scale,
        y:(detail.clientY - rect.top) / scale,
        anchorX:detail.clientX - surfaceRect.left,
        anchorY:detail.clientY - surfaceRect.top,
      } : null;
    }
    if (event.type === 'gesturemove' && this.pinch) {
      const start = this.pinch;
      const fit = Math.min(this.surface.clientWidth / canvas.width, this.surface.clientHeight / canvas.height);
      const scale = Math.min(Math.max(4, fit), Math.max(Math.min(1, fit), start.scale * distance / start.distance));
      this.setScale(scale);
      this.surface.scrollLeft = start.x * scale - start.anchorX;
      this.surface.scrollTop = start.y * scale - start.anchorY;
    }
    if (event.type === 'gestureend') this.pinch = null;
  }
}
