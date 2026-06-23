param(
  [ValidateSet('tauri', 'android', 'ios', 'all', '')]
  [string]$Target = '',
  [switch]$Release,
  [switch]$Help
)

if ($Help) {
  Write-Host @"
用法: .\build.ps1 [[-Target] <类型>] [-Release] [-Help]

Target 类型:
  tauri     构建 Tauri 桌面端 (Windows NSIS/MSI)
  android   构建 Android APK (Capacitor)
  ios       构建 iOS 归档 (Capacitor, 仅 macOS)
  all       构建所有平台

参数:
  -Release  发布模式 (默认 debug)
  -Help     显示此帮助

示例:
  .\build.ps1                  # 构建桌面端 (debug)
  .\build.ps1 tauri -Release   # 构建桌面端 (release)
  .\build.ps1 android          # 构建 Android APK
"@
  return
}

$ErrorActionPreference = 'Stop'

# ---- Auto-detect tool paths ----
$rustPaths = @(
  if ($env:CARGO_HOME) { "$env:CARGO_HOME\bin" }
  if ($env:RUSTUP_HOME) { "$env:RUSTUP_HOME\bin" }
  "$env:USERPROFILE\.cargo\bin"
  "$env:LOCALAPPDATA\Programs\Rust\bin"
  "C:\Program Files\Rust\bin"
  "C:\Rust\.cargo\bin"
)

$nsisPaths = @(
  "${env:ProgramFiles(x86)}\NSIS"
  "${env:ProgramFiles}\NSIS"
  "$env:LOCALAPPDATA\NSIS"
)

$mingwPaths = @(
  "D:\code\mingw64\bin"
  "C:\mingw64\bin"
  "$env:USERPROFILE\mingw64\bin"
)

$additionalPaths = @()
$resolve = { param($paths) $paths | Where-Object { $_ -and (Test-Path "$_\*" -ErrorAction SilentlyContinue) } | Select-Object -First 1 }

$rustBin = &$resolve $rustPaths
$nsisBin = &$resolve $nsisPaths
$mingwBin = &$resolve $mingwPaths

if ($rustBin) { $additionalPaths += $rustBin }
if ($nsisBin) { $additionalPaths += $nsisBin }
if ($mingwBin) { $additionalPaths += $mingwBin }

if ($additionalPaths.Count -gt 0) {
  $env:PATH = ($additionalPaths -join ';') + ';' + $env:PATH
  Write-Host "已添加工具路径: $($additionalPaths -join ', ')" -ForegroundColor Cyan
}

$env:CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS = "fallback"

# ---- Detect build profile ----
$profile = if ($Release) { 'release' } else { 'debug' }
$cargoProfile = if ($Release) { '' } else { '--debug' }

# ---- Detect target ----
if (!$Target) { $Target = 'tauri' }

# ---- Build ----
switch ($Target) {
  'tauri' {
    Write-Host "=== 构建 Tauri 桌面端 ($profile) ===" -ForegroundColor Yellow
    if ($Release) {
      npm run tauri:build
    } else {
      npm run tauri:build -- --debug
    }
    if ($LASTEXITCODE -ne 0) { throw "Tauri build failed" }
    Write-Host "构建成功! 输出:" -ForegroundColor Green
    foreach ($pattern in @('msi\*.msi', 'nsis\*.exe', 'appimage\*.AppImage', 'deb\*.deb', 'dmg\*.dmg')) {
      $parts = $pattern -split '\\'
      $dir = if ($parts.Count -eq 2) { $parts[0] } else { '' }
      $filter = if ($parts.Count -eq 2) { $parts[1] } else { $pattern }
      $dirPath = if ($dir) { "src-tauri\target\release\bundle\$dir" } else { "src-tauri\target\release\bundle" }
      $files = Get-ChildItem -LiteralPath $dirPath -Filter $filter -ErrorAction SilentlyContinue
      foreach ($f in $files) {
        Write-Host "  $($f.FullName) ($([math]::Round($f.Length/1KB)) KB)" -ForegroundColor Cyan
      }
    }
  }
  'android' {
    Write-Host "=== 构建 Android APK ===" -ForegroundColor Yellow
    Write-Host "检查 Java 版本..." -ForegroundColor Gray
    try {
      $javaVer = (java -version 2>&1 | Select-String 'version "(\d+)').Matches.Groups[1].Value
      if ([int]$javaVer -lt 21) { Write-Host "警告: 建议 Java 21+ (当前: $javaVer)" -ForegroundColor Yellow }
    } catch { Write-Host "警告: 无法检测 Java 版本" -ForegroundColor Yellow }
    Write-Host "同步 Capacitor..." -ForegroundColor Gray
    npx cap sync android
    if ($LASTEXITCODE -ne 0) { throw "Capacitor sync failed" }
    Write-Host "构建 APK..." -ForegroundColor Gray
    pushd android
    try {
      if ($Release) {
        ./gradlew assembleRelease
      } else {
        ./gradlew assembleDebug
      }
      if ($LASTEXITCODE -ne 0) { throw "Android build failed" }
    } finally { popd }
    $apkDir = "android\app\build\outputs\apk\$profile"
    $apks = Get-ChildItem -LiteralPath $apkDir -Filter "*.apk" -ErrorAction SilentlyContinue
    Write-Host "构建成功! APK:" -ForegroundColor Green
    foreach ($f in $apks) {
      Write-Host "  $($f.FullName) ($([math]::Round($f.Length/1KB)) KB)" -ForegroundColor Cyan
    }
  }
  'ios' {
    Write-Host "=== 构建 iOS 归档 ===" -ForegroundColor Yellow
    if ($env:OS -or $env:USERDOMAIN) {
      Write-Host "警告: iOS 构建需要 macOS" -ForegroundColor Yellow
    }
    Write-Host "安装 iOS 平台..." -ForegroundColor Gray
    npm install @capacitor/ios
    Write-Host "添加并同步 iOS 平台..." -ForegroundColor Gray
    npx cap add ios
    npx cap sync ios
    Write-Host "构建归档..." -ForegroundColor Gray
    pushd ios/App
    try {
      xcodebuild -project App.xcodeproj -scheme App -configuration Release -sdk iphoneos -archivePath "$PWD/build/App.xcarchive" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO archive
      if ($LASTEXITCODE -ne 0) { throw "iOS build failed" }
    } finally { popd }
    pushd ios/App/build
    try {
      $version = (Get-Content "$PSScriptRoot\package.json" | ConvertFrom-Json).version
      Compress-Archive -Path "App.xcarchive" -DestinationPath "通用阅读器_${version}_ios.zip"
      Write-Host "构建成功! 输出: ios/App/build/通用阅读器_${version}_ios.zip" -ForegroundColor Green
    } finally { popd }
  }
  'all' {
    Write-Host "=== 构建所有平台 ===" -ForegroundColor Yellow
    & $PSScriptRoot\build.ps1 tauri -Release
    if ($LASTEXITCODE -ne 0) { throw "Tauri build failed" }
    & $PSScriptRoot\build.ps1 android
    if ($LASTEXITCODE -ne 0) { throw "Android build failed" }
    try {
      & $PSScriptRoot\build.ps1 ios
    } catch {
      Write-Host "iOS 构建跳过 (需要 macOS)" -ForegroundColor Yellow
    }
    Write-Host "所有平台构建完成!" -ForegroundColor Green
  }
}
