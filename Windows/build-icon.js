#!/usr/bin/env node
/**
 * build-icon.js — Sync the Windows/Electron app icon from the HarmonyOS master icon.
 *
 * WHY THIS EXISTS
 *   The HarmonyOS main project (AppScope/resources/base/media/icon.png, 1024x1024 RGBA)
 *   is the single source of truth for the product icon. This script derives every
 *   Windows Electron icon artifact from that one master so the two builds can never
 *   drift apart again.
 *
 * OUTPUTS
 *   build/icon.ico          multi-size ICO containing 16,24,32,48,64,128,256 (7 images)
 *   renderer/icon.png       512x512 PNG (used by the renderer / BrowserWindow)
 *
 * DEPENDENCIES
 *   NONE. Deliberately dependency-free. `png-to-ico` is declared in package.json, but
 *   requiring it would make this script fail whenever node_modules is absent (CI, a
 *   fresh clone, or a concurrent `npm install`). Everything needed — PNG decode
 *   (zlib inflate + PNG filter reconstruction), high-quality downsampling, PNG encode
 *   (zlib deflate) and the ICO container writer — is implemented below on top of
 *   Node's built-in `zlib`/`fs` only.
 *
 * USAGE
 *   node build-icon.js                  # normal run (from Windows/ or anywhere)
 *   node build-icon.js --master X.png   # use an alternative master PNG (one-off replacement)
 *   node build-icon.js --sizes 16,32    # override ICO sizes
 *   node build-icon.js --png-size 256   # override renderer PNG size
 *   node build-icon.js --check          # verify outputs match the master, write nothing
 *
 * NOTE ON --master
 *   The Windows icon currently derives from a 600x600 replacement artwork that was
 *   supplied directly (see ICON_MASTER_OVERRIDE below), not from the HarmonyOS master.
 *   Pass --master explicitly, or update ICON_MASTER_OVERRIDE, when re-running.
 *
 * Exit codes: 0 = success, 1 = failure.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const WINDOWS_DIR = __dirname;
const WORKSPACE_ROOT = path.resolve(WINDOWS_DIR, '..');

/** HarmonyOS master icon (source of truth) and the HarmonyOS layered-icon parts. */
const MASTER_ICON = path.join(WORKSPACE_ROOT, 'AppScope', 'resources', 'base', 'media', 'icon.png');
const MASTER_FOREGROUND = path.join(WORKSPACE_ROOT, 'AppScope', 'resources', 'base', 'media', 'foreground.png');

/** Outputs. */
const OUT_ICO = path.join(WINDOWS_DIR, 'build', 'icon.ico');
const OUT_PNG = path.join(WINDOWS_DIR, 'renderer', 'icon.png');

const DEFAULT_ICO_SIZES = [16, 24, 32, 48, 64, 128, 256];
const DEFAULT_PNG_SIZE = 512;

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = { icoSizes: DEFAULT_ICO_SIZES.slice(), pngSize: DEFAULT_PNG_SIZE, check: false, master: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--check') {
      opts.check = true;
    } else if (a === '--master') {
      const raw = argv[++i];
      if (!raw) throw new Error('--master requires a path to a PNG');
      opts.master = path.resolve(raw);
    } else if (a === '--sizes') {
      const raw = argv[++i];
      if (!raw) throw new Error('--sizes requires a comma-separated list');
      const sizes = raw
        .split(',')
        .map((s) => parseInt(s.trim(), 10))
        .filter((n) => Number.isFinite(n) && n > 0);
      if (!sizes.length) throw new Error('--sizes parsed to an empty list');
      opts.icoSizes = sizes;
    } else if (a === '--png-size') {
      const n = parseInt(argv[++i], 10);
      if (!Number.isFinite(n) || n <= 0) throw new Error('--png-size requires a positive integer');
      opts.pngSize = n;
    } else if (a === '--help' || a === '-h') {
      console.log('usage: node build-icon.js [--master path/to/master.png] [--sizes 16,24,...] [--png-size N] [--check]');
      process.exit(0);
    } else {
      throw new Error('unknown argument: ' + a);
    }
  }
  // ICO stores width/height as a single byte; 256 is encoded as 0. Larger is invalid.
  for (const s of opts.icoSizes) {
    if (s > 256) throw new Error(`ICO size ${s} exceeds the 256px ICO limit`);
  }
  return opts;
}

// ---------------------------------------------------------------------------
// PNG decoding  (zlib inflate + PNG filter reconstruction)
// ---------------------------------------------------------------------------

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** Number of bytes per complete pixel for a given PNG colour type / bit depth. */
function channelsFor(colorType) {
  switch (colorType) {
    case 0: return 1; // greyscale
    case 2: return 3; // truecolour
    case 3: return 1; // indexed
    case 4: return 2; // greyscale + alpha
    case 6: return 4; // truecolour + alpha
    default: throw new Error('unsupported PNG colour type: ' + colorType);
  }
}

/**
 * Decode a PNG buffer into {width, height, data:Uint8Array RGBA8}.
 * Supports the non-interlaced 8-bit forms used by the HarmonyOS media assets
 * (colour types 0/2/4/6). Palette and <8-bit depths are rejected loudly rather
 * than silently mis-decoded.
 */
function decodePng(buf) {
  if (buf.length < 8 || !buf.subarray(0, 8).equals(PNG_SIG)) {
    throw new Error('not a PNG file (bad signature)');
  }

  let pos = 8;
  let width = 0;
  let height = 0;
  let bitDepth = 0;
  let colorType = 0;
  let interlace = 0;
  const idat = [];

  while (pos + 8 <= buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString('latin1', pos + 4, pos + 8);
    const dataStart = pos + 8;
    const dataEnd = dataStart + len;
    if (dataEnd > buf.length) throw new Error(`truncated PNG chunk ${type}`);

    if (type === 'IHDR') {
      width = buf.readUInt32BE(dataStart);
      height = buf.readUInt32BE(dataStart + 4);
      bitDepth = buf[dataStart + 8];
      colorType = buf[dataStart + 9];
      interlace = buf[dataStart + 12];
    } else if (type === 'IDAT') {
      idat.push(buf.subarray(dataStart, dataEnd));
    } else if (type === 'IEND') {
      break;
    }
    pos = dataEnd + 4; // skip CRC
  }

  if (!width || !height) throw new Error('PNG is missing a valid IHDR chunk');
  if (interlace !== 0) throw new Error('interlaced PNG is not supported');
  if (bitDepth !== 8) throw new Error('only 8-bit PNGs are supported (got ' + bitDepth + ')');
  if (colorType === 3) throw new Error('indexed-colour PNG is not supported');
  if (!idat.length) throw new Error('PNG contains no IDAT data');

  const channels = channelsFor(colorType);
  const bpp = channels; // bytes per pixel (bit depth is 8)
  const stride = width * bpp;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const expected = height * (stride + 1);
  if (raw.length < expected) {
    throw new Error(`inflated PNG is short: got ${raw.length}, expected ${expected}`);
  }

  // Undo the per-scanline filters (PNG spec §9.2).
  const out = new Uint8Array(height * stride);
  let prev = new Uint8Array(stride); // all-zero for the first scanline
  let rp = 0;

  for (let y = 0; y < height; y++) {
    const filter = raw[rp++];
    const line = raw.subarray(rp, rp + stride);
    rp += stride;
    const cur = out.subarray(y * stride, (y + 1) * stride);

    switch (filter) {
      case 0: // None
        cur.set(line);
        break;
      case 1: // Sub
        for (let i = 0; i < stride; i++) {
          const left = i >= bpp ? cur[i - bpp] : 0;
          cur[i] = (line[i] + left) & 0xff;
        }
        break;
      case 2: // Up
        for (let i = 0; i < stride; i++) cur[i] = (line[i] + prev[i]) & 0xff;
        break;
      case 3: // Average
        for (let i = 0; i < stride; i++) {
          const left = i >= bpp ? cur[i - bpp] : 0;
          cur[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xff;
        }
        break;
      case 4: { // Paeth
        for (let i = 0; i < stride; i++) {
          const a = i >= bpp ? cur[i - bpp] : 0;
          const b = prev[i];
          const c = i >= bpp ? prev[i - bpp] : 0;
          const p = a + b - c;
          const pa = Math.abs(p - a);
          const pb = Math.abs(p - b);
          const pc = Math.abs(p - c);
          let pred;
          if (pa <= pb && pa <= pc) pred = a;
          else if (pb <= pc) pred = b;
          else pred = c;
          cur[i] = (line[i] + pred) & 0xff;
        }
        break;
      }
      default:
        throw new Error('unknown PNG filter type ' + filter + ' on scanline ' + y);
    }
    prev = cur;
  }

  // Normalise to RGBA8.
  const rgba = new Uint8Array(width * height * 4);
  if (colorType === 6) {
    rgba.set(out);
  } else if (colorType === 2) {
    for (let i = 0, j = 0; i < out.length; i += 3, j += 4) {
      rgba[j] = out[i];
      rgba[j + 1] = out[i + 1];
      rgba[j + 2] = out[i + 2];
      rgba[j + 3] = 255;
    }
  } else if (colorType === 4) {
    for (let i = 0, j = 0; i < out.length; i += 2, j += 4) {
      rgba[j] = rgba[j + 1] = rgba[j + 2] = out[i];
      rgba[j + 3] = out[i + 1];
    }
  } else if (colorType === 0) {
    for (let i = 0, j = 0; i < out.length; i++, j += 4) {
      rgba[j] = rgba[j + 1] = rgba[j + 2] = out[i];
      rgba[j + 3] = 255;
    }
  }

  return { width, height, data: rgba };
}

// ---------------------------------------------------------------------------
// Resampling — box filter for clean integer downscales, bilinear otherwise
// ---------------------------------------------------------------------------

/**
 * Resample an RGBA8 image. Downscales use an area-average (box) filter which is
 * the right choice for large integer reductions such as 1024 -> 256, avoiding the
 * aliasing a naive sampler would produce. Upscales fall back to bilinear.
 *
 * Alpha is handled as straight (non-premultiplied) alpha; the source master is
 * fully opaque, so colour/alpha bleeding is not a concern here.
 */
function resample(src, srcW, srcH, dstW, dstH) {
  if (dstW === srcW && dstH === srcH) return Uint8Array.from(src);

  const dst = new Uint8Array(dstW * dstH * 4);
  const scaleX = srcW / dstW;
  const scaleY = srcH / dstH;

  if (dstW <= srcW && dstH <= srcH) {
    // --- Area-average (box) filter ---
    for (let dy = 0; dy < dstH; dy++) {
      const sy0 = dy * scaleY;
      const sy1 = (dy + 1) * scaleY;
      const yStart = Math.floor(sy0);
      const yEnd = Math.min(Math.ceil(sy1), srcH);

      for (let dx = 0; dx < dstW; dx++) {
        const sx0 = dx * scaleX;
        const sx1 = (dx + 1) * scaleX;
        const xStart = Math.floor(sx0);
        const xEnd = Math.min(Math.ceil(sx1), srcW);

        let r = 0, g = 0, b = 0, a = 0, wsum = 0;

        for (let sy = yStart; sy < yEnd; sy++) {
          const wy = Math.min(sy1, sy + 1) - Math.max(sy0, sy);
          if (wy <= 0) continue;
          for (let sx = xStart; sx < xEnd; sx++) {
            const wx = Math.min(sx1, sx + 1) - Math.max(sx0, sx);
            if (wx <= 0) continue;
            const w = wx * wy;
            const si = (sy * srcW + sx) * 4;
            r += src[si] * w;
            g += src[si + 1] * w;
            b += src[si + 2] * w;
            a += src[si + 3] * w;
            wsum += w;
          }
        }

        const di = (dy * dstW + dx) * 4;
        if (wsum > 0) {
          dst[di] = Math.round(r / wsum);
          dst[di + 1] = Math.round(g / wsum);
          dst[di + 2] = Math.round(b / wsum);
          dst[di + 3] = Math.round(a / wsum);
        }
      }
    }
    return dst;
  }

  // --- Bilinear (used for upscales) ---
  for (let dy = 0; dy < dstH; dy++) {
    const fy = Math.min((dy + 0.5) * scaleY - 0.5, srcH - 1);
    const y0 = Math.max(0, Math.floor(fy));
    const y1 = Math.min(srcH - 1, y0 + 1);
    const ty = Math.max(0, fy - y0);

    for (let dx = 0; dx < dstW; dx++) {
      const fx = Math.min((dx + 0.5) * scaleX - 0.5, srcW - 1);
      const x0 = Math.max(0, Math.floor(fx));
      const x1 = Math.min(srcW - 1, x0 + 1);
      const tx = Math.max(0, fx - x0);

      const di = (dy * dstW + dx) * 4;
      for (let c = 0; c < 4; c++) {
        const p00 = src[(y0 * srcW + x0) * 4 + c];
        const p10 = src[(y0 * srcW + x1) * 4 + c];
        const p01 = src[(y1 * srcW + x0) * 4 + c];
        const p11 = src[(y1 * srcW + x1) * 4 + c];
        const top = p00 + (p10 - p00) * tx;
        const bot = p01 + (p11 - p01) * tx;
        dst[di + c] = Math.round(top + (bot - top) * ty);
      }
    }
  }
  return dst;
}

// ---------------------------------------------------------------------------
// PNG encoding
// ---------------------------------------------------------------------------

function crc32Table() {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
}
const CRC_TABLE = crc32Table();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'latin1');
  const body = Buffer.concat([typeBuf, data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}

/** Encode RGBA8 pixels as an 8-bit truecolour+alpha (colour type 6) PNG. */
function encodePng(rgba, width, height) {
  const stride = width * 4;
  // One filter byte (0 = None) per scanline. The data is smooth icon artwork, so
  // zlib's default deflate already compresses it well; filters add no real gain.
  const rawLen = height * (stride + 1);
  const raw = Buffer.alloc(rawLen);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    Buffer.from(rgba.buffer, rgba.byteOffset + y * stride, stride).copy(raw, y * (stride + 1) + 1);
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // colour type: RGBA
  ihdr[10] = 0; // deflate
  ihdr[11] = 0; // adaptive filtering
  ihdr[12] = 0; // no interlace

  return Buffer.concat([
    PNG_SIG,
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

// ---------------------------------------------------------------------------
// ICO container writer
// ---------------------------------------------------------------------------

/**
 * Build a multi-size .ico. Each entry stores a full PNG (Vista+ PNG-compressed ICO
 * entries, which Windows and electron-builder both support), so the 256x256 image is
 * preserved without the size blow-up of a raw BGRA bitmap.
 *
 * Layout: ICONDIR (6 bytes) + N * ICONDIRENTRY (16 bytes) + payloads.
 * Width/height 256 is encoded as 0 per the ICO spec.
 */
function buildIco(images) {
  const count = images.length;
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0); // reserved, must be 0
  header.writeUInt16LE(1, 2); // type: 1 = icon
  header.writeUInt16LE(count, 4);

  const entries = Buffer.alloc(count * 16);
  let offset = 6 + count * 16;

  images.forEach((img, i) => {
    const e = i * 16;
    entries[e] = img.size >= 256 ? 0 : img.size;
    entries[e + 1] = img.size >= 256 ? 0 : img.size;
    entries[e + 2] = 0; // palette colours (0 = not palettised)
    entries[e + 3] = 0; // reserved
    entries.writeUInt16LE(1, e + 4); // colour planes
    entries.writeUInt16LE(32, e + 6); // bits per pixel
    entries.writeUInt32LE(img.png.length, e + 8); // bytes in resource
    entries.writeUInt32LE(offset, e + 12); // file offset of payload
    offset += img.png.length;
  });

  return Buffer.concat([header, entries, ...images.map((i) => i.png)]);
}

/** Read back an ICO's embedded image count + per-entry geometry (for verification). */
function parseIco(buf) {
  if (buf.length < 6) throw new Error('ICO too short');
  const reserved = buf.readUInt16LE(0);
  const type = buf.readUInt16LE(2);
  const count = buf.readUInt16LE(4);
  const images = [];
  for (let i = 0; i < count; i++) {
    const e = 6 + i * 16;
    if (e + 16 > buf.length) throw new Error('ICO directory truncated');
    const w = buf[e] === 0 ? 256 : buf[e];
    const h = buf[e + 1] === 0 ? 256 : buf[e + 1];
    const bpp = buf.readUInt16LE(e + 6);
    const bytes = buf.readUInt32LE(e + 8);
    const offset = buf.readUInt32LE(e + 12);
    const payload = buf.subarray(offset, offset + bytes);
    const isPng = payload.length > 8 && payload.subarray(0, 8).equals(PNG_SIG);
    images.push({ width: w, height: h, bpp, bytes, offset, isPng });
  }
  return { reserved, type, count, images };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function rel(p) {
  const r = path.relative(WORKSPACE_ROOT, p);
  return r.startsWith('..') ? p : r;
}

function sha256(buf) {
  return require('crypto').createHash('sha256').update(buf).digest('hex');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  const opts = parseArgs(process.argv.slice(2));

  // --master lets a one-off replacement icon be used instead of the HarmonyOS master.
  // The default remains the HarmonyOS project icon (single source of truth).
  const masterPath = opts.master || MASTER_ICON;
  console.log('[build-icon] master     : ' + rel(masterPath) + (opts.master ? '  (override via --master)' : ''));
  if (!fs.existsSync(masterPath)) {
    throw new Error('master icon not found at ' + masterPath);
  }

  const masterBuf = fs.readFileSync(masterPath);
  console.log('[build-icon] master size: ' + masterBuf.length + ' bytes, sha256=' + sha256(masterBuf).slice(0, 16) + '...');

  const master = decodePng(masterBuf);
  console.log(`[build-icon] master image: ${master.width}x${master.height} RGBA8`);
  if (master.width !== master.height) {
    console.warn(`[build-icon] WARNING: master is not square (${master.width}x${master.height}); output may be distorted`);
  }

  // Derive every ICO size from the master (never from a previously downscaled copy,
  // so repeated runs cannot accumulate resampling loss).
  const icoImages = [];
  for (const size of opts.icoSizes) {
    const px = resample(master.data, master.width, master.height, size, size);
    const png = encodePng(px, size, size);
    icoImages.push({ size, png });
    console.log(`[build-icon]   ico ${String(size).padStart(3)}x${String(size).padEnd(3)} -> ${png.length} bytes`);
  }

  const icoBuf = buildIco(icoImages);
  const pngPx = resample(master.data, master.width, master.height, opts.pngSize, opts.pngSize);
  const pngBuf = encodePng(pngPx, opts.pngSize, opts.pngSize);

  // Validate before committing anything to disk.
  const parsed = parseIco(icoBuf);
  if (parsed.type !== 1 || parsed.count !== icoImages.length) {
    throw new Error(`ICO self-check failed: type=${parsed.type} count=${parsed.count}`);
  }
  const checkPng = decodePng(pngBuf);
  if (checkPng.width !== opts.pngSize || checkPng.height !== opts.pngSize) {
    throw new Error('renderer PNG self-check failed');
  }

  if (opts.check) {
    const same =
      fs.existsSync(OUT_ICO) && fs.readFileSync(OUT_ICO).equals(icoBuf) &&
      fs.existsSync(OUT_PNG) && fs.readFileSync(OUT_PNG).equals(pngBuf);
    console.log('[build-icon] --check: outputs ' + (same ? 'MATCH the master' : 'DIFFER from the master'));
    process.exit(same ? 0 : 1);
  }

  fs.mkdirSync(path.dirname(OUT_ICO), { recursive: true });
  fs.mkdirSync(path.dirname(OUT_PNG), { recursive: true });
  fs.writeFileSync(OUT_ICO, icoBuf);
  fs.writeFileSync(OUT_PNG, pngBuf);

  console.log(`[build-icon] wrote ${rel(OUT_ICO)} (${icoBuf.length} bytes, ${parsed.count} images: ${parsed.images.map((i) => i.width).join(', ')})`);
  console.log(`[build-icon] wrote ${rel(OUT_PNG)} (${pngBuf.length} bytes, ${opts.pngSize}x${opts.pngSize})`);
  console.log('[build-icon] OK');
}

try {
  main();
} catch (err) {
  console.error('[build-icon] FAILED: ' + (err && err.message ? err.message : err));
  if (process.env.BUILD_ICON_DEBUG) console.error(err);
  process.exit(1);
}
