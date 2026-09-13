import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import sharp from 'sharp';
import potrace from 'potrace';
import pngToIco from 'png-to-ico';

const site = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(site, '..');
const brand = join(root, 'dist/brand');
const assets = [];
const approved = await readFile(join(brand, 'sources/myna-clay-approved.png'));
const sourceHash = createHash('sha256').update(approved).digest('hex');
const sha = (data) => createHash('sha256').update(data).digest('hex');
const uri = (data) => `data:image/png;base64,${data.toString('base64')}`;
const raster = (data, size) => sharp(data).resize(size, size).png().toBuffer();
async function output(relative, data) {
  await mkdir(dirname(join(root, relative)), { recursive: true });
  await writeFile(join(root, relative), data);
  assets.push({ path: relative, bytes: Buffer.byteLength(data), sha256: sha(data) });
}
const exp = (name, data) => output(`dist/brand/exports/${name}`, data);
const web = (name, data) => output(`site/public/${name}`, data);
const trace = (data) => new Promise((res, rej) => potrace.trace(data, {
  threshold: 110, color: '#000000', background: 'transparent', turdSize: 20, optTolerance: 0.25,
}, (err, svg) => err ? rej(err) : res(svg)));

// Trace the supplied glyph artwork into genuine vector contours, then optically
// crop the SVG viewport. No bitmap/checkerboard is embedded in the templates.
async function glyph(name) {
  let svg = await trace(await readFile(join(brand, `sources/myna-${name}-source.png`)));
  const { data, info } = await sharp(Buffer.from(svg)).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let left = info.width, top = info.height, right = 0, bottom = 0;
  for (let y = 0; y < info.height; y++) for (let x = 0; x < info.width; x++) {
    if (data[(y * info.width + x) * 4 + 3] > 128) {
      left = Math.min(left, x); top = Math.min(top, y); right = Math.max(right, x); bottom = Math.max(bottom, y);
    }
  }
  const side = Math.max(right - left, bottom - top) * 1.07;
  const x = (left + right - side) / 2, y = (top + bottom - side) / 2;
  svg = svg.replace(/viewBox="[^"]*"/, `viewBox="${x} ${y} ${side} ${side}"`);
  return svg;
}
const outline = await glyph('outline');
const filled = await glyph('filled');
// Optical weight for status-bar sizes: a direct reduction of the large
// outline falls below one physical pixel. Expand the existing ink contours.
const smallOutline = outline.replaceAll('stroke="none"', '').replaceAll('<path ', '<path stroke="#000000" stroke-width="40" stroke-linejoin="round" ');
await exp('myna-outline-small.svg', smallOutline);
await web('brand/myna-outline-small.svg', smallOutline);
for (const [name, svg] of [['outline', outline], ['filled', filled]]) {
  const inverse = svg.replaceAll('fill="#000000"', 'fill="#ffffff"');
  await exp(`myna-${name}.svg`, svg);
  await exp(`myna-${name}-white.svg`, inverse);
  await web(`brand/myna-${name}.svg`, svg);
  await web(`brand/myna-${name}-white.svg`, inverse);
  for (const size of [16, 18, 20, 22, 24, 32, 64, 128, 256, 512, 1024]) {
    const sized = name === 'outline' && size <= 32 ? smallOutline : svg;
    const sizedInverse = sized.replaceAll('#000000', '#ffffff');
    await exp(`png/myna-${name}-${size}.png`, await raster(Buffer.from(sized), size));
    await exp(`png/myna-${name}-white-${size}.png`, await raster(Buffer.from(sizedInverse), size));
  }
  const assetName = name === 'outline' ? 'MynaOutline' : 'MynaFilled';
  const images = [];
  for (const scale of [1, 2, 3]) {
    const filename = `${assetName}@${scale}x.png`;
    await output(`apps/macos/Resources/Assets.xcassets/${assetName}.imageset/${filename}`, await raster(Buffer.from(name === 'outline' ? smallOutline : svg), 18 * scale));
    images.push({ idiom: 'universal', filename, scale: `${scale}x` });
  }
  await output(`apps/macos/Resources/Assets.xcassets/${assetName}.imageset/Contents.json`, JSON.stringify({ images, info: { author: 'xcode', version: 1 }, properties: { 'template-rendering-intent': 'template' } }, null, 2));
}

// Export the coloured source with a traced clipping contour. The generated
// source's neutral matte is excluded by chroma, never shipped as fake alpha.
const borderedSource = await readFile(join(brand, 'sources/myna-bordered-source.png'));
const pixels = await sharp(borderedSource).removeAlpha().raw().toBuffer({ resolveWithObject: true });
const mask = Buffer.alloc(pixels.info.width * pixels.info.height * 3, 255);
for (let i = 0; i < mask.length; i += 3) {
  const channels = [pixels.data[i], pixels.data[i + 1], pixels.data[i + 2]];
  if (Math.max(...channels) - Math.min(...channels) > 40) mask.fill(0, i, i + 3);
}
const maskPng = await sharp(mask, { raw: { width: pixels.info.width, height: pixels.info.height, channels: 3 } }).png().toBuffer();
const maskSvg = await trace(maskPng);
const maskPaths = [...maskSvg.matchAll(/<path[^>]*>/g)].map(m => m[0]).join('');
const borderedSvg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1254" height="1254" viewBox="0 0 1254 1254"><title>Myna bordered colour companion</title><desc>Raster colour artwork with a vector clipping contour.</desc><defs><clipPath id="bird">${maskPaths}</clipPath></defs><image width="1254" height="1254" clip-path="url(#bird)" xlink:href="${uri(borderedSource)}"/></svg>`;
const bordered = await sharp(Buffer.from(borderedSvg)).png().toBuffer();
await exp('myna-bordered.svg', borderedSvg);
await exp('myna-bordered.png', bordered);
await exp('myna-bordered.webp', await sharp(bordered).webp({ lossless: true }).toBuffer());
await web('brand/myna-bordered.png', await raster(bordered, 512));

// The parked clay master already contains the selected icon tile. Keep its
// artwork and baked lighting; only encode the standard transparent outer mask.
const approved1024 = await raster(approved, 1024);
const appSvg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1024" height="1024" viewBox="0 0 1024 1024"><title>Myna approved full-bird clay icon</title><defs><clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath></defs><image width="1024" height="1024" clip-path="url(#tile)" xlink:href="${uri(approved1024)}"/></svg>`;
const appIcon = await sharp(Buffer.from(appSvg)).png().toBuffer();
await output('dist/brand/app-icon.svg', appSvg);
await exp('myna-clay-original.png', approved);
await exp('myna-app-icon.svg', appSvg);
await exp('myna-app-icon.png', appIcon);
await exp('myna-app-icon.webp', await sharp(appIcon).webp({ lossless: true }).toBuffer());
await exp('myna-clay-original.jpg', await sharp(approved).jpeg({ quality: 95 }).toBuffer());
await web('app-icon.png', appIcon);
await web('dmg-window.png', await sharp(join(brand, 'sources/dmg-window-approved-brand.png')).resize(1320, 896).png().toBuffer());
const artworkImages = [];
for (const scale of [1, 2, 3]) {
  const filename = `MynaArtwork@${scale}x.png`;
  await output(`apps/macos/Resources/Assets.xcassets/MynaArtwork.imageset/${filename}`, await raster(appIcon, 64 * scale));
  artworkImages.push({ idiom: 'universal', filename, scale: `${scale}x` });
}
await output('apps/macos/Resources/Assets.xcassets/MynaArtwork.imageset/Contents.json', JSON.stringify({ images: artworkImages, info: { author: 'xcode', version: 1 } }, null, 2));
const appImages = [];
for (const size of [16, 32, 128, 256, 512]) for (const scale of [1, 2]) {
  const filename = `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`;
  const data = await raster(appIcon, size * scale);
  await output(`apps/macos/Resources/Assets.xcassets/AppIcon.appiconset/${filename}`, data);
  await exp(`Myna.iconset/${filename}`, data);
  appImages.push({ idiom: 'mac', size: `${size}x${size}`, scale: `${scale}x`, filename });
}
await output('apps/macos/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json', JSON.stringify({ images: appImages, info: { author: 'xcode', version: 1 } }, null, 2));
execFileSync('iconutil', ['-c', 'icns', join(brand, 'exports/Myna.iconset'), '-o', join(brand, 'exports/Myna.icns')]);
const icns = await readFile(join(brand, 'exports/Myna.icns'));
assets.push({ path: 'dist/brand/exports/Myna.icns', bytes: icns.length, sha256: sha(icns) });
await exp('Myna.ico', await pngToIco(await Promise.all([16, 24, 32, 48, 64, 128, 256].map(n => raster(appIcon, n)))));
for (const size of [16, 24, 32, 48, 64, 128, 256, 512, 1024]) await exp(`png/myna-app-${size}.png`, await raster(appIcon, size));
// Unmasked mobile/web images, provided as artwork rather than a new iOS app.
const unmasked = await sharp(approved).extract({ left: 125, top: 125, width: 1000, height: 1000 }).resize(1024, 1024).removeAlpha().png().toBuffer();
await exp('mobile/myna-1024.png', unmasked);
for (const size of [180, 192, 512]) {
  const data = await raster(unmasked, size);
  await exp(`mobile/myna-${size}.png`, data);
  await web(size === 180 ? 'apple-touch-icon.png' : `brand/app-${size}.png`, data);
}
const faviconCanvas = await sharp({ create: { width: 256, height: 256, channels: 4, background: '#fffaf7' } })
  .composite([{ input: await raster(bordered, 256) }]).png().toBuffer();
const faviconSvg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="256" height="256" viewBox="0 0 256 256"><image width="256" height="256" xlink:href="${uri(faviconCanvas)}"/></svg>`;
await web('favicon.svg', faviconSvg);
await web('favicon.ico', await pngToIco(await Promise.all([16, 32, 48].map(n => raster(faviconCanvas, n)))));
await web('brand/safari-pinned-tab.svg', filled);
for (const size of [16, 32, 48, 64]) await web(`brand/favicon-${size}.png`, await raster(faviconCanvas, size));

const social = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1200" height="630"><rect width="1200" height="630" fill="#F5EFE2"/><text x="76" y="97" font-family="Georgia,serif" font-size="31" fill="#6B5F4F">Myna · for Mac</text><text x="76" y="231" font-family="Georgia,serif" font-size="64" fill="#1A1714">Your eyes are tired.</text><text x="76" y="317" font-family="Georgia,serif" font-style="italic" font-size="64" fill="#0A4F44">Your Mac can read.</text><text x="79" y="399" font-family="Georgia,serif" font-size="27" fill="#3A332A">A quiet voice for your Mac.</text><text x="79" y="442" font-family="Georgia,serif" font-size="27" fill="#3A332A">Private, local text to speech.</text><image x="785" y="140" width="365" height="365" xlink:href="${uri(appIcon)}"/><path d="M76 524H1124" stroke="#1A1714" stroke-opacity=".15"/><text x="79" y="574" font-family="Arial,sans-serif" font-size="18" fill="#6B5F4F">Free · open source · Apple Silicon · myna.prerakgada.in</text></svg>`;
const socialPng = await sharp(Buffer.from(social)).png().toBuffer();
await exp('myna-social-card.svg', social);
await exp('myna-social-card.png', socialPng);
await output('site/app/opengraph-image.png', socialPng);
await output('site/app/twitter-image.png', socialPng);
const preview = `<!doctype html><meta charset="utf-8"><title>Myna approved brand</title><style>body{font:16px system-ui;background:#eee;padding:30px;color:#20132a}h1{font-size:26px}.row{display:flex;gap:24px;flex-wrap:wrap;margin:20px 0}.card{background:white;padding:20px;border-radius:18px}img.large{width:210px;height:210px;object-fit:contain}.dark{background:#161218;color:white}.sizes{display:flex;gap:22px;align-items:end;min-height:90px}figure{margin:0;text-align:center;font-size:12px}figure img{display:block;margin:10px auto}.caption{margin-top:8px}</style><h1>Myna · approved full bird</h1><div class="row">${[['myna-app-icon.png','Clay app icon'],['myna-bordered.png','Bordered colour'],['myna-outline.svg','Outline'],['myna-filled.svg','Filled']].map(([src,label])=>`<div class="card"><img class="large" src="${src}"><div class="caption">${label}</div></div>`).join('')}</div>${['outline','filled'].map(name=>`<div class="row"><div class="card"><b>${name} · light</b><div class="sizes">${[16,18,20,22,24,32].map(n=>`<figure><img src="png/myna-${name}-${n}.png" width="${n}" height="${n}">${n}px</figure>`).join('')}</div></div><div class="card dark"><b>${name} · dark</b><div class="sizes">${[16,18,20,22,24,32].map(n=>`<figure><img src="png/myna-${name}-white-${n}.png" width="${n}" height="${n}">${n}px</figure>`).join('')}</div></div></div>`).join('')}`;
await exp('preview.html', preview);
await writeFile(join(brand, 'manifest.json'), JSON.stringify({ identity: 'Myna full-bird soft-clay icon', approvedSourceSha256: sourceHash, sources: 'sources/', assets: assets.sort((a,b) => a.path.localeCompare(b.path)) }, null, 2) + '\n');
execFileSync('zip', ['-q','-r','-FS','Myna-Brand-Assets.zip','README.md','manifest.json','sources','exports'], { cwd: brand });
await web('brand/Myna-Brand-Assets.zip', await readFile(join(brand, 'Myna-Brand-Assets.zip')));
const deployed = assets.filter(a => a.path.startsWith('site/')).map(a => ({ ...a, path: a.path.slice(5) }));
await writeFile(join(site, 'brand-assets.json'), JSON.stringify({ approvedSourceSha256: sourceHash, files: deployed }, null, 2) + '\n');
console.log(`Built ${assets.length} brand assets and site copies from ${sourceHash}.`);
