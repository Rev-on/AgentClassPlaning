# 一键构建“带图标 + 版本信息”的 Windows 安装包
# 用法：右键本脚本 → “使用 PowerShell 运行”，或直接双击同目录的
#       “以管理员身份打包.bat”（会弹出 UAC，点“是”）。
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# 国内镜像（可去掉注释改用官方源）
$env:ELECTRON_MIRROR = 'https://npmmirror.com/mirrors/electron/'
$env:ELECTRON_BUILDER_BINARIES_MIRROR = 'https://npmmirror.com/mirrors/electron-builder-binaries/'

Write-Host ''
Write-Host '==> 开始打包（需要管理员权限写入 exe 图标/版本资源）...' -ForegroundColor Cyan
npm run dist

$setup = Join-Path $PSScriptRoot 'dist\RevTechingMaster-Setup-1.0.0.exe'
if (Test-Path $setup) {
  Write-Host ''
  Write-Host ('完成！安装包：') -ForegroundColor Green
  Write-Host ('  ' + $setup) -ForegroundColor White
  Write-Host '主程序与安装器均已嵌入品牌图标与版本信息。' -ForegroundColor Green
} else {
  Write-Host '构建未找到产物，请检查上方错误输出。' -ForegroundColor Red
  exit 1
}
