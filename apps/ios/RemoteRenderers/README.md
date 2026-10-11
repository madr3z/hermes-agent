# Focused phone renderers

The SwiftUI app embeds these local renderers in WKWebView. noVNC 1.7.0 renders RFB; xterm 6.0.0 and Fit 0.11.0 render ANSI terminal output. They have no server URL, token, WebSocket, filesystem or arbitrary navigation authority. Native URLSession owns authenticated WSS connections and passes bytes through a named message bridge. The local HTML's CSP disables network connections. Each renderer generation is bound to one native stream; late frames cannot drive a replacement surface.

Reproduce the checked-in asset with Node and npm:

```sh
cd apps/ios/RemoteRenderers
npm ci --ignore-scripts --no-audit --no-fund
npm test
npm run build
```

`package-lock.json` pins package tarball integrity and esbuild 0.28.1. The build wraps the self-contained ESM output in an async function because noVNC's capability probe uses top-level await; it does not change upstream code or enable dynamic evaluation. No remote assets or CDN are loaded.

Corresponding upstream source: [noVNC 1.7.0](https://github.com/novnc/noVNC/tree/v1.7.0), [xterm 6.0.0](https://github.com/xtermjs/xterm.js/tree/6.0.0), and the exact npm packages named in the lockfile. Upstream code is unmodified. noVNC's MPL-2.0, authors, incorporated pako MIT notice, and xterm/Fit MIT licenses accompany the app resources. The integration source is `renderer.js` and `index.html`; rebuilding preserves the upstream legal comments in the bundle.

Screen touch uses noVNC's pointer gestures: tap/drag, two-finger right click/scroll. Two-finger pinch changes only the local viewport, including while viewing without control; it never sends Ctrl+wheel to the guest. Fit resets the viewport, 1:1 shows guest pixels at native size, and Pan moves the local viewport with one finger. Zoom uses noVNC's public scaleViewport property so later pointer input still maps to the correct guest pixels. Rotation never resizes the guest desktop. Keyboard, modifier, navigation and paste controls remain focused on this remote surface. Terminal paste uses xterm's bracketed-paste handling. A disconnected or replaced stream requires explicit Reconnect; another terminal attachment (4409) never causes an automatic takeover loop.
