import {build} from 'esbuild';
import {writeFile,copyFile} from 'node:fs/promises';
const result = await build({entryPoints:['renderer.js'],bundle:true,minify:true,target:'safari17',format:'esm',write:false});
// noVNC probes WebCodecs with top-level await. A local async script preserves it
// without file-origin module loading or granting the viewer network authority.
await writeFile('../HermesPhone/Resources/Remote/renderer.js', '(async()=>{\n' + result.outputFiles[0].text + '\n})().catch(()=>window.webkit.messageHandlers.remote.postMessage({type:"failure",message:"Remote renderer could not load."}));\n');
await copyFile('node_modules/@xterm/xterm/css/xterm.css','../HermesPhone/Resources/Remote/xterm.css');
