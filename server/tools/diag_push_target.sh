#!/usr/bin/env bash
# 推送目标诊断：查清"服务端把通知推给了哪个 token"，以及该 token 是否是最新的。
# 只读，不改任何数据。
cd /opt/rev-server || exit 1

echo "===== 1. 全部设备记录（按最近上报排序）====="
node -e '
const t = require("./src/tasks");
const d = t.listDevices();
console.log("有效设备总数:", d.length);
d.forEach((x, i) => {
  const ago = Math.round((Date.now() - x.updatedAt) / 60000);
  console.log(
    String(i + 1).padStart(2) + ". id=" + String(x.id).padEnd(40) +
    " tokenLen=" + String(x.token).length +
    " token=" + String(x.token).slice(0, 16) + "..." +
    " 上报于 " + new Date(x.updatedAt).toLocaleString() +
    " (" + ago + " 分钟前)"
  );
});
'

echo
echo "===== 2. data/devices.json 原始记录（看有没有 token 为空的脏数据）====="
node -e '
const fs = require("fs");
const f = "data/devices.json";
if (!fs.existsSync(f)) { console.log("(无 devices.json)"); process.exit(0); }
const a = JSON.parse(fs.readFileSync(f, "utf8"));
console.log("记录数:", a.length);
a.forEach((d, i) => {
  const len = String(d.token || "").length;
  console.log(
    String(i + 1).padStart(2) + ". id=" + JSON.stringify(d.id) +
    " tokenLen=" + len +
    (len === 0 ? "  <== 空 token！" : "")
  );
});
'

echo
echo "===== 3. 最近 5 个任务的 deviceId 与所推 token ====="
node -e '
const fs = require("fs");
const t = require("./src/tasks");
const a = JSON.parse(fs.readFileSync("data/tasks.json", "utf8"));
const recent = a.slice().sort((x, y) => y.createdAt - x.createdAt).slice(0, 5);
recent.forEach((k) => {
  const tok = t.tokenOf(k.deviceId);
  console.log(
    "task=" + k.id + " type=" + k.type +
    " notifyId=" + JSON.stringify(k.notifySeed) +
    "\n   deviceId=" + JSON.stringify(k.deviceId) +
    "\n   该 deviceId 的 token 长度=" + String(tok).length +
    (String(tok).length === 0 ? "  <== 查不到 token！会走广播" : "")
  );
});
'

echo
echo "===== 4. 统计：最近任务用的 deviceId 有多少个不同值 ====="
node -e '
const fs = require("fs");
const a = JSON.parse(fs.readFileSync("data/tasks.json", "utf8"));
const recent = a.slice().sort((x, y) => y.createdAt - x.createdAt).slice(0, 30);
const m = {};
recent.forEach((k) => { m[k.deviceId] = (m[k.deviceId] || 0) + 1; });
Object.keys(m).forEach((k) => console.log("  deviceId=" + JSON.stringify(k) + " 出现 " + m[k] + " 次"));
'
