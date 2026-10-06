#!/usr/bin/env node
/**
 * sign.js — 为 Windows 产物签名（NSIS 安装包 / 免安装版 / 应用主程序）。
 *
 * 为什么需要
 *   未签名的 exe 在 Windows 上会被 SmartScreen 拦成"危险应用"（未知发布者），
 *   安装/运行都要用户手动点"仍要运行"。签名后至少能证明文件未被篡改、
 *   并显示发布者名称。
 *
 * 两种证书
 *   1) 自签名（仓库内 build/codesign-selfsigned.pfx，密码 agentbeike）
 *      · 免费、立即可用，能消除"未签名"状态，Windows 可显示发布者。
 *      · ⚠️ **不能**消除 SmartScreen 的"危险应用"警告 —— 自签根证书不在
 *        公共信任链里，必须让用户手动信任（见 --trust）或改用真证书。
 *   2) 真实代码签名证书（OV/EV，需购买）
 *      · 只有这种能真正消除 SmartScreen 警告（新证书仍需积累下载声誉）。
 *      · 用法：set CODESIGN_PFX=D:\path\your.pfx & set CODESIGN_PASSWORD=xxx
 *
 * 用法
 *   node sign.js                      # 用仓库内自签名证书签 dist/ 下所有产物
 *   node sign.js --trust              # 额外把自签证书装入本机信任库（需管理员）
 *   node sign.js --verify             # 只校验，不签名
 *   set CODESIGN_PFX=... & set CODESIGN_PASSWORD=... & node sign.js   # 用真实证书
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const WIN = __dirname;
const DIST = path.join(WIN, 'dist');
const BUILD = path.join(WIN, 'build');

const SELF_PFX = path.join(BUILD, 'codesign-selfsigned.pfx');
const SELF_CER = path.join(BUILD, 'codesign-selfsigned.cer');
const SELF_PW = 'agentbeike';

/** 定位 signtool.exe（Windows SDK 自带）。 */
function findSigntool() {
  const roots = [
    'C:\\Program Files (x86)\\Windows Kits\\10\\bin',
    'C:\\Program Files\\Windows Kits\\10\\bin',
  ];
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    const versions = fs.readdirSync(root).sort().reverse();
    for (const v of versions) {
      for (const arch of ['x64', 'x86']) {
        const p = path.join(root, v, arch, 'signtool.exe');
        if (fs.existsSync(p)) return p;
      }
    }
  }
  return null;
}

/** 待签名的产物（存在才签）。 */
function targets() {
  const out = [];
  if (!fs.existsSync(DIST)) return out;
  for (const f of fs.readdirSync(DIST)) {
    if (f.toLowerCase().endsWith('.exe')) out.push(path.join(DIST, f));
  }
  const unpacked = path.join(DIST, 'win-unpacked');
  if (fs.existsSync(unpacked)) {
    for (const f of fs.readdirSync(unpacked)) {
      if (f.toLowerCase().endsWith('.exe')) out.push(path.join(unpacked, f));
    }
  }
  return out;
}

function main() {
  const args = process.argv.slice(2);
  const doTrust = args.includes('--trust');
  const verifyOnly = args.includes('--verify');

  const signtool = findSigntool();
  if (!signtool) {
    console.error('[sign] 找不到 signtool.exe：请安装 Windows SDK（含 Signing Tools）');
    process.exit(1);
  }
  console.log('[sign] signtool : ' + signtool);

  const files = targets();
  if (!files.length) {
    console.error('[sign] dist/ 下没有可签名的 exe，请先执行 npm run dist');
    process.exit(1);
  }

  // ---- 仅校验 ----
  if (verifyOnly) {
    let bad = 0;
    files.forEach((f) => {
      try {
        execFileSync(signtool, ['verify', '/pa', '/all', f], { stdio: 'pipe' });
        console.log('  VERIFIED  ' + path.basename(f));
      } catch (e) {
        bad++;
        console.log('  FAILED    ' + path.basename(f) + '  ' + String(e.stderr || e.message).split('\n')[0]);
      }
    });
    console.log(bad ? '[sign] ' + bad + ' 个文件校验失败' : '[sign] 全部校验通过');
    process.exit(bad ? 1 : 0);
  }

  // ---- 选择证书 ----
  const envPfx = process.env.CODESIGN_PFX;
  const useEnv = !!(envPfx && fs.existsSync(envPfx));
  const pfx = useEnv ? envPfx : SELF_PFX;
  const pw = useEnv ? (process.env.CODESIGN_PASSWORD || '') : SELF_PW;

  if (!fs.existsSync(pfx)) {
    console.error('[sign] 证书不存在: ' + pfx);
    console.error('        自签证书可用 PowerShell 生成：');
    console.error('        New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=Agent备课" `');
    console.error('          -CertStoreLocation Cert:\\CurrentUser\\My');
    process.exit(1);
  }
  console.log('[sign] 证书     : ' + path.basename(pfx) + (useEnv ? '  (来自 CODESIGN_PFX)' : '  (仓库内自签名)'));
  if (!useEnv) {
    console.log('[sign] ⚠️  自签名证书无法消除 SmartScreen "危险应用" 警告；');
    console.log('        只有购买 OV/EV 证书才能真正解决（见文件头说明）。');
  }

  // ---- 签名（SHA256 + RFC3161 时间戳，保证过期后签名仍有效）----
  let failed = 0;
  files.forEach((f) => {
    const base = path.basename(f);
    try {
      execFileSync(signtool, [
        'sign', '/f', pfx, '/p', pw,
        '/fd', 'SHA256',
        '/tr', 'http://timestamp.digicert.com', '/td', 'SHA256',
        f,
      ], { stdio: 'pipe' });
      console.log('  SIGNED    ' + base);
    } catch (e) {
      failed++;
      const msg = String(e.stderr || e.stdout || e.message).trim().split('\n').slice(-2).join(' ');
      console.log('  FAILED    ' + base + '  ' + msg);
    }
  });

  if (failed) {
    console.log('[sign] ' + failed + ' 个文件签名失败');
    process.exit(1);
  }

  // ---- 可选：把自签证书装入本机信任库，使签名链可校验 ----
  if (doTrust && !useEnv && fs.existsSync(SELF_CER)) {
    console.log('');
    console.log('[sign] 正在把自签证书装入本机信任库（当前用户）...');
    ['Root', 'TrustedPublisher'].forEach((store) => {
      try {
        if (store === 'Root') {
          // Root 存储用 certutil：Import-Certificate 会弹 UI，在无人值守场景失败
          execFileSync('certutil', ['-user', '-addstore', '-f', 'Root', SELF_CER], { stdio: 'pipe' });
        } else {
          execFileSync('certutil', ['-user', '-addstore', '-f', 'TrustedPublisher', SELF_CER], { stdio: 'pipe' });
        }
        console.log('  已装入 ' + store);
      } catch (e) {
        console.log('  装入 ' + store + ' 失败（可能需管理员）：' + String(e.message).split('\n')[0]);
      }
    });
  }

  console.log('');
  console.log('[sign] 完成。校验：node sign.js --verify');
}

main();
