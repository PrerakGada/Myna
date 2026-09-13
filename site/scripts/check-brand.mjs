import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const site = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(site, '..');
const brand = join(root, 'dist/brand');
const sha = data => createHash('sha256').update(data).digest('hex');
const deployed = JSON.parse(await readFile(join(site, 'brand-assets.json'), 'utf8'));
for (const item of deployed.files) {
  const data = await readFile(join(site, item.path));
  assert.equal(sha(data), item.sha256, `Stale site brand file: ${item.path}`);
}
for (const required of ['public/app-icon.png', 'public/dmg-window.png', 'public/favicon.svg', 'public/favicon.ico', 'public/apple-touch-icon.png', 'public/brand/myna-filled.svg', 'public/brand/myna-outline.svg', 'public/brand/Myna-Brand-Assets.zip', 'app/opengraph-image.png', 'app/twitter-image.png']) {
  assert.ok(deployed.files.some(a => a.path === required), `Missing deployment asset: ${required}`);
}
console.log(`Verified ${deployed.files.length} site brand assets.`);
if (!process.argv.includes('--site')) {
  const { default: sharp } = await import('sharp');
  const manifest = JSON.parse(await readFile(join(brand, 'manifest.json'), 'utf8'));
  assert.equal(sha(await readFile(join(brand, 'sources/myna-clay-approved.png'))), manifest.approvedSourceSha256);
  assert.equal(deployed.approvedSourceSha256, manifest.approvedSourceSha256);
  for (const item of manifest.assets) assert.equal(sha(await readFile(join(root, item.path))), item.sha256, item.path);
  for (const name of ['AppIcon.appiconset', 'MynaOutline.imageset', 'MynaFilled.imageset', 'MynaArtwork.imageset']) {
    const folder = join(root, 'apps/macos/Resources/Assets.xcassets', name);
    const catalog = JSON.parse(await readFile(join(folder, 'Contents.json'), 'utf8'));
    for (const image of catalog.images) {
      const metadata = await sharp(join(folder, image.filename)).metadata();
      const base = image.size ? parseFloat(image.size) : name === 'MynaArtwork.imageset' ? 64 : 18;
      assert.equal(metadata.width, base * parseFloat(image.scale), image.filename);
      assert.equal(metadata.width, metadata.height, image.filename);
    }
  }
  for (const name of ['outline', 'filled']) {
    const svg = await readFile(join(brand, `exports/myna-${name}.svg`), 'utf8');
    assert.ok(svg.includes('<path') && !svg.includes('<image'), `Expected vector ${name}`);
    const {data, info} = await sharp(join(brand, `exports/png/myna-${name}-18.png`)).ensureAlpha().raw().toBuffer({resolveWithObject:true});
    assert.equal(data[3], 0);
    let ink = 0;
    for (let i=0; i<data.length; i+=info.channels) {
      if (data[i+3] > 0) { assert.equal(data[i]+data[i+1]+data[i+2], 0); ink += data[i+3]; }
    }
    assert.ok(ink > 2000, `Empty or too faint ${name} glyph`);
  }
  const icon = await sharp(join(brand, 'exports/myna-app-icon.png')).ensureAlpha().raw().toBuffer({resolveWithObject:true});
  assert.equal(icon.data[3], 0);
  const ico = await readFile(join(brand, 'exports/Myna.ico'));
  assert.equal(ico.readUInt16LE(2), 1); assert.equal(ico.readUInt16LE(4), 7);
  const icns = await readFile(join(brand, 'exports/Myna.icns'));
  assert.equal(icns.toString('ascii',0,4),'icns'); assert.equal(icns.readUInt32BE(4),icns.length);
  console.log(`Verified ${manifest.assets.length} project assets, native catalogs, template ink/alpha and app icon containers.`);
}
