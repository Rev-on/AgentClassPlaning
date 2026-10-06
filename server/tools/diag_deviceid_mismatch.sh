#!/usr/bin/env bash
# 核对 deviceId 一致性：任务是哪个 id、设备表是哪个 id，两者能否匹配。
cd /opt/rev-server || exit 1
node -e '
const fs = require("fs");
const a = JSON.parse(fs.readFileSync("data/tasks.json", "utf8"));
const devs = JSON.parse(fs.readFileSync("data/devices.json", "utf8"));

const tids = new Set(a.map((x) => x.deviceId));
const dids = new Set(devs.map((x) => x.id));

console.log("任务里的 deviceId 去重数 :", tids.size);
console.log("设备表的 id   去重数    :", dids.size);
console.log("");

let inter = 0;
tids.forEach((x) => { if (dids.has(x)) { inter++; } });
console.log("两者交集:", inter, inter === 0 ? " <<== 完全对不上（推送必然走广播或失败）" : "");

console.log("");
console.log("任务 deviceId 样例:");
[...tids].slice(0, 8).forEach((x) => console.log("   " + JSON.stringify(x)));
console.log("设备 id 样例:");
[...dids].slice(0, 8).forEach((x) => console.log("   " + JSON.stringify(x)));

// 格式特征判断
const tDash = [...tids].filter((x) => String(x).indexOf("-") >= 0).length;
const dDash = [...dids].filter((x) => String(x).indexOf("-") >= 0).length;
console.log("");
console.log("任务 deviceId 含横线(0000-0000 形式)的条数:", tDash, "/", tids.size);
console.log("设备 id       含横线(UUID 形式)的条数   :", dDash, "/", dids.size);

// 长度分布
const tLen = {};
[...tids].forEach((x) => { const L = String(x).length; tLen[L] = (tLen[L] || 0) + 1; });
const dLen = {};
[...dids].forEach((x) => { const L = String(x).length; dLen[L] = (dLen[L] || 0) + 1; });
console.log("任务 deviceId 长度分布:", JSON.stringify(tLen));
console.log("设备 id       长度分布:", JSON.stringify(dLen));
'
