# diagnose-startup.ps1 — Agent备课 电脑版启动诊断
#
# 用途：应用双击后无窗口/秒退时，收集判断所需的最小事实集。
# 用法：右键"使用 PowerShell 运行"，或在 PowerShell 里执行：
#         powershell -ExecutionPolicy Bypass -File diagnose-startup.ps1
#       把屏幕输出（或生成的 diag-report.txt）发回即可定位问题。

$ErrorActionPreference = 'Continue'
$out = @()
function Say($s) { $out += $s; Write-Host $s }

Say "==================== Agent备课 启动诊断 ===================="
Say ("时间: " + (Get-Date))
Say ("系统: " + [Environment]::OSVersion.VersionString)
Say ("交互式会话: " + [Environment]::UserInteractive)

# ---------- 1. 定位程序 ----------
Say ""
Say "---------- 1. 程序位置 ----------"
$cands = @(
  "$env:LOCALAPPDATA\Programs\Agent备课",
  "$env:LOCALAPPDATA\Programs\rev-techingmaster-windows",
  "$env:PROGRAMFILES\Agent备课",
  "${env:ProgramFiles(x86)}\Agent备课"
)
$found = $null
foreach ($c in $cands) { if (Test-Path $c) { $found = $c; Say "已安装目录: $c" } }
if (-not $found) { Say "未在常见安装目录找到（可能用的是免安装版）" }

Say ""
Say "桌面/开始菜单快捷方式:"
Get-ChildItem "$env:USERPROFILE\Desktop", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match 'Agent|备课' } | ForEach-Object { Say ("  " + $_.FullName) }

# ---------- 2. 环境变量（关键） ----------
Say ""
Say "---------- 2. 环境变量（ELECTRON_RUN_AS_NODE 会导致主进程秒退） ----------"
foreach ($scope in @('Process', 'User', 'Machine')) {
  $v = [Environment]::GetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $scope)
  Say ("  $scope : " + $(if ([string]::IsNullOrEmpty($v)) { '<未设置>' } else { "'$v'  <-- 问题！需删除" }))
}
Say ("  ELECTRON_NO_ATTACH_CONSOLE : " + [Environment]::GetEnvironmentVariable('ELECTRON_NO_ATTACH_CONSOLE', 'Process'))

# ---------- 3. TEMP ----------
Say ""
Say "---------- 3. 临时目录（NSIS/portable 解压依赖它） ----------"
Say ("  TEMP = " + $env:TEMP)
Say ("  存在 = " + (Test-Path $env:TEMP))
$nsCount = 0
Get-ChildItem "$env:TEMP" -Directory -Filter "ns*.tmp" -ErrorAction SilentlyContinue |
  ForEach-Object { $nsCount++; Say ("  残留NSIS目录: " + $_.Name) }
Say ("  残留 NSIS 目录数 = $nsCount" + $(if ($nsCount -gt 0) { "  <-- 清掉它们（见下方修复）" } else { "" }))
try {
  $tf = Join-Path $env:TEMP ("probe_" + [guid]::NewGuid().ToString('N') + ".tmp")
  Set-Content $tf 'x' -ErrorAction Stop; Remove-Item $tf -Force
  Say "  TEMP 可写 = 是"
} catch { Say ("  TEMP 可写 = 否  <-- 问题！" + $_.Exception.Message) }

# ---------- 4. 用户数据目录 ----------
Say ""
Say "---------- 4. 用户数据目录 ----------"
$ud = "$env:APPDATA\rev-techingmaster-windows"
Say ("  路径 = $ud")
Say ("  存在 = " + (Test-Path $ud))
if (Test-Path $ud) {
  $lock = Get-ChildItem $ud -Force -Filter "Singleton*" -ErrorAction SilentlyContinue
  if ($lock) { $lock | ForEach-Object { Say ("  锁文件: " + $_.Name + "  <-- 删掉它（应用没在运行时可安全删除）") } }
  else { Say "  无锁文件 = 正常" }
  Say ("  最后修改 = " + (Get-Item $ud).LastWriteTime)
}

# ---------- 5. 事件日志 ----------
Say ""
Say "---------- 5. 最近的应用程序错误日志 ----------"
$ev = Get-WinEvent -FilterHashtable @{LogName = 'Application'; StartTime = (Get-Date).AddDays(-3) } -MaxEvents 200 -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match 'Agent|备课|electron' -or $_.ProviderName -match 'Application Error' } |
  Select-Object -First 6
if ($ev) {
  $ev | ForEach-Object {
    Say ("  [" + $_.TimeCreated + "] " + $_.ProviderName)
    Say ("      " + ($_.Message -replace "`r?`n", ' ').Substring(0, [Math]::Min(300, $_.Message.Length)))
  }
} else { Say "  无相关错误记录" }

# ---------- 6. 尝试带日志启动 ----------
Say ""
Say "---------- 6. 尝试启动并捕获输出 ----------"
$exe = $null
if ($found) { $exe = (Get-ChildItem $found -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
if ($exe) {
  Say "  启动: $exe"
  $logOut = Join-Path $env:TEMP "agentbeike-startup.out.log"
  $logErr = Join-Path $env:TEMP "agentbeike-startup.err.log"
  Remove-Item $logOut, $logErr -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $exe -PassThru -RedirectStandardOutput $logOut -RedirectStandardError $logErr -ErrorAction SilentlyContinue
  if ($p) {
    Start-Sleep -Seconds 12
    if ($p.HasExited) { Say ("  ✗ 进程已退出，退出码 = " + $p.ExitCode + "  (0x" + ('{0:X}' -f $p.ExitCode) + ")") }
    else { Say "  ✓ 进程仍在运行（窗口可能已打开）" }
  } else { Say "  ✗ 无法启动该进程" }
  if (Test-Path $logOut) { Say "  stdout:"; Get-Content $logOut | Select-Object -First 20 | ForEach-Object { Say ("    " + $_) } }
  if (Test-Path $logErr) { Say "  stderr:"; Get-Content $logErr | Select-Object -First 20 | ForEach-Object { Say ("    " + $_) } }
} else { Say "  跳过（未定位到 exe）" }

# ---------- 输出 ----------
Say ""
Say "==================== 诊断结束 ===================="
$out | Set-Content -Path (Join-Path (Get-Location) "diag-report.txt") -Encoding UTF8
Write-Host ""
Write-Host "报告已保存到: $(Join-Path (Get-Location) 'diag-report.txt')" -ForegroundColor Green
