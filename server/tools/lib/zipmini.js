/* ============================================================================
 * 迷你 ZIP 读写器（纯 JS，零依赖）—— 供 test_export_ai_metadata.js 做**真实产物**验证
 *
 * 为什么自己写而不用现成库：
 *   1. server/node_modules 里没有 jszip（只有 express 全家桶）；
 *   2. Windows/node_modules 里也没有 jszip 包（renderer 用的是
 *      renderer/js/vendor/jszip.min.js 这个浏览器版单文件）；
 *   3. 鸿蒙侧的 oh_modules/@ohos/jszip 是 ESM 且 import '@ohos/node-polyfill'，
 *      Node 无法直接 require。
 *   与其"换个库里凑"，不如用 Node 内置 zlib 直接按 ZIP 规范读写 ——
 *   规格简单、行为确定，且**读的是真实字节**（比调用同一个库自证更可信）。
 *
 * 支持范围（恰好覆盖 OOXML 包）：
 *   · 读取：stored(0) 与 deflate(8)，中央目录定位，UTF-8 文件名
 *   · 写入：deflate(8)，含中央目录与 EOCD
 *   · CRC-32：标准 IEEE 多项式
 * ========================================================================== */
'use strict';

const zlib = require('zlib');

/* ---------------- CRC-32（IEEE 802.3，ZIP 用） ---------------- */
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/* ---------------- 读取 ---------------- */

/** 找到 EOCD（0x06054b50），返回中央目录偏移与条目数；允许 zip 尾部有注释 */
function findEocd(buf) {
  const min = 22;
  const start = Math.max(0, buf.length - min - 0xffff);
  for (let i = buf.length - min; i >= start; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) {
      return {
        total: buf.readUInt16LE(i + 10),
        cdSize: buf.readUInt32LE(i + 12),
        cdOffset: buf.readUInt32LE(i + 16)
      };
    }
  }
  throw new Error('不是合法的 ZIP：未找到 EOCD 记录');
}

/**
 * 解析 zip，返回条目数组：
 *   { name, method, compressedSize, uncompressedSize, crcOk, read(): Buffer }
 * read() 会解压并**校验 CRC**（不符直接抛错）——这正是"真实字节、真的能解包"的证据。
 */
function readZip(buf) {
  const eocd = findEocd(buf);
  const entries = [];
  let p = eocd.cdOffset;
  for (let i = 0; i < eocd.total; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error('中央目录记录签名错误 @' + p);
    const method = buf.readUInt16LE(p + 10);
    const crc = buf.readUInt32LE(p + 16);
    const compressedSize = buf.readUInt32LE(p + 20);
    const uncompressedSize = buf.readUInt32LE(p + 24);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const localOffset = buf.readUInt32LE(p + 42);
    const name = buf.toString('utf8', p + 46, p + 46 + nameLen);
    const e = { name, method, compressedSize, uncompressedSize, crcOk: null, _buf: buf, _crc: crc };
    e.read = function () {
      // 本地文件头：签名 + 文件名长度 + 扩展区长度 可能与本处不同，须按本地头计算数据起点
      if (buf.readUInt32LE(localOffset) !== 0x04034b50) throw new Error(name + ': 本地文件头签名错误');
      const lNameLen = buf.readUInt16LE(localOffset + 26);
      const lExtraLen = buf.readUInt16LE(localOffset + 28);
      const dataStart = localOffset + 30 + lNameLen + lExtraLen;
      const raw = buf.subarray(dataStart, dataStart + compressedSize);
      let out;
      if (method === 0) out = Buffer.from(raw);
      else if (method === 8) out = zlib.inflateRawSync(raw);
      else throw new Error(name + ': 不支持的压缩方法 ' + method);
      const actual = crc32(out);
      if (actual !== crc) {
        throw new Error(name + ': CRC-32 校验失败（期望 ' + crc.toString(16) + '，实得 ' + actual.toString(16) + '）');
      }
      e.crcOk = true;
      return out;
    };
    entries.push(e);
    p += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

/** 名字 → 条目；不存在返回 undefined（调用方自行断言） */
function findEntry(entries, name) {
  return entries.find((e) => e.name === name);
}

/* ---------------- 写入（构造 fixture 与"改造前"基线包） ---------------- */

/**
 * 写一个 deflate 压缩的 zip。
 * files: [ [name, contentString|Buffer], ... ]
 */
function writeZip(files) {
  const chunks = [];
  const central = [];
  let offset = 0;

  for (const [name, content] of files) {
    const nameBuf = Buffer.from(name, 'utf8');
    const data = Buffer.isBuffer(content) ? content : Buffer.from(String(content), 'utf8');
    const comp = zlib.deflateRawSync(data);
    const crc = crc32(data);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);   // version needed
    local.writeUInt16LE(0x0800, 6); // UTF-8 名称标志
    local.writeUInt16LE(8, 8);    // deflate
    local.writeUInt16LE(0, 10);   // time
    local.writeUInt16LE(0x21, 12); // date (1980-01-01)
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(comp.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);
    chunks.push(local, nameBuf, comp);

    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0);
    cd.writeUInt16LE(20, 4);   // version made by
    cd.writeUInt16LE(20, 6);   // version needed
    cd.writeUInt16LE(0x0800, 8);
    cd.writeUInt16LE(8, 10);
    cd.writeUInt16LE(0, 12);
    cd.writeUInt16LE(0x21, 14);
    cd.writeUInt32LE(crc, 16);
    cd.writeUInt32LE(comp.length, 20);
    cd.writeUInt32LE(data.length, 24);
    cd.writeUInt16LE(nameBuf.length, 28);
    cd.writeUInt32LE(offset, 42);
    central.push(cd, nameBuf);

    offset += local.length + nameBuf.length + comp.length;
  }

  const cdBuf = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(files.length, 8);
  eocd.writeUInt16LE(files.length, 10);
  eocd.writeUInt32LE(cdBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...chunks, cdBuf, eocd]);
}

module.exports = { crc32, readZip, findEntry, writeZip };
