// Render brand SVGs to PNG:  node render.mjs <in.svg> <out.png> <width> [<in2> <out2> <w2> ...]
import { Resvg } from '@resvg/resvg-js';
import { readFileSync, writeFileSync } from 'node:fs';
const a = process.argv.slice(2);
for (let i = 0; i < a.length; i += 3) {
  const r = new Resvg(readFileSync(a[i]), {
    fitTo: { mode: 'width', value: Number(a[i + 2]) },
    font: { loadSystemFonts: false, fontFiles: ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf'], defaultFontFamily: 'Segoe UI' },
  });
  writeFileSync(a[i + 1], r.render().asPng());
  console.log('wrote', a[i + 1]);
}
