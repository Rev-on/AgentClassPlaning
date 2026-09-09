@echo off
rem 以管理员身份重新启动打包脚本（会触发 Windows UAC 确认框，点“是”继续）
rem 构建完成后窗口保留，可直接看到产物路径
set SCRIPT=%~dp0build-with-icon.ps1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File','%SCRIPT%'" 
