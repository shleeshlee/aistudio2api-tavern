# ============================================
# AIStudio2API for SillyTavern —— Windows 版：安装 / 更新 / 卸载，一条命令
# 在 PowerShell 里运行：
#   irm https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.ps1 | iex
# 运行后选 1 安装 / 2 更新 / 3 卸载。
# 免交互：先设 $env:AISTUDIO2API_ACTION = 'install'（或 update / uninstall），
#        可选 $env:AISTUDIO2API_ST = '酒馆目录'
# 程序优先从上游下载，上游不可用时改用备份 fork
# 整个脚本包在一个块里：irm | iex 时用 return 结束，不会把 PowerShell 窗口关掉
# ============================================
& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Sources  = @('Mag1cFall/AIStudio2API', 'shleeshlee/AIStudio2API')  # 上游在前，备份 fork 在后
$Name     = 'AIStudio2API'
$RepoZip  = 'https://github.com/shleeshlee/aistudio2api-tavern/archive/refs/heads/main.zip'
$OneLine  = 'irm https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.ps1 | iex'
$DefaultDir = Join-Path $HOME 'aistudio2api'
$LinkFile   = Join-Path $HOME '.aistudio2api-tavern'   # 插件改用独立安装目录时记在这里（插件也读）

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }
function Ask($q, $def) {
  $hint = if ($def -eq 'y') { 'Y/n' } else { 'y/N' }
  $r = Read-Host "  $q [$hint]"
  if ([string]::IsNullOrWhiteSpace($r)) { $r = $def }
  return ($r -match '^[Yy]')
}

$Interactive = [string]::IsNullOrEmpty($env:AISTUDIO2API_ACTION)

Write-Host ''
Write-Host '  ==========================================' -ForegroundColor Blue
Write-Host '    AIStudio2API for SillyTavern (Windows)' -ForegroundColor Blue
Write-Host '  ==========================================' -ForegroundColor Blue
Write-Host ''

# ---------- 找酒馆 ----------
function Test-ST($d) {
  return ($d -and (Test-Path (Join-Path $d 'server.js')) -and (Test-Path (Join-Path $d 'public\scripts\extensions')))
}
$StDir = $env:AISTUDIO2API_ST
if (-not (Test-ST $StDir)) {
  $StDir = $null
  $cands = @((Get-Location).Path, (Join-Path (Get-Location).Path 'SillyTavern'), (Join-Path $HOME 'SillyTavern'),
             (Join-Path $HOME 'Desktop\SillyTavern'), (Join-Path $HOME 'Documents\SillyTavern'), (Join-Path $HOME 'Downloads\SillyTavern'))
  foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    $cands += (Join-Path $drive.Root 'SillyTavern')
  }
  foreach ($c in $cands) { if (Test-ST $c) { $StDir = $c; break } }
}
if (-not $StDir) {
  Info '在常见位置没找到酒馆，正在主目录里搜索…'
  $hit = Get-ChildItem -Path $HOME -Filter server.js -Recurse -Depth 4 -ErrorAction SilentlyContinue |
         Where-Object { Test-ST $_.DirectoryName } | Select-Object -First 1
  if ($hit) { $StDir = $hit.DirectoryName }
}
if (-not $StDir -and $Interactive) {
  $p = Read-Host '  没找到 SillyTavern，请粘贴酒馆文件夹的路径（含 server.js 的那个）'
  $p = $p.Trim('"', ' ')
  if (Test-ST $p) { $StDir = $p }
}
if (-not $StDir) { Fail '找不到 SillyTavern。进到酒馆文件夹里再运行，或设置 $env:AISTUDIO2API_ST'; return }
$StDir = (Resolve-Path $StDir).Path

$PluginDir = Join-Path $StDir "plugins\$Name"
$ExtDir    = Join-Path $StDir "public\scripts\extensions\third-party\$Name"
$Config    = Join-Path $StDir 'config.yaml'
$StPort = 8000
if (Test-Path $Config) {
  $m = Select-String -Path $Config -Pattern '^port:\s*(\d+)' | Select-Object -First 1
  if ($m) { $StPort = [int]$m.Matches[0].Groups[1].Value }
}

if ($env:AISTUDIO2API_HOME) { $AppDir = $env:AISTUDIO2API_HOME }
elseif ((Test-Path $LinkFile) -and (Test-Path ((Get-Content $LinkFile -TotalCount 1).Trim()))) { $AppDir = (Get-Content $LinkFile -TotalCount 1).Trim() }
else { $AppDir = $DefaultDir }
$BinPath = Join-Path $AppDir 'aistudio2api.exe'
$VerFile = Join-Path $AppDir '.termux-version'   # 与其他平台共用的版本记录
$Current = if (Test-Path $VerFile) { (Get-Content $VerFile -TotalCount 1).Trim() } else { '' }
$Installed = Test-Path $PluginDir

# ---------- 菜单 ----------
$Action = $env:AISTUDIO2API_ACTION
if ($Interactive) {
  Write-Host "  酒馆：$StDir"
  if ($Installed) {
    $v = if ($Current) { $Current } else { '未下载' }
    Write-Host "  状态：已安装  程序 $v" -ForegroundColor Green
  } else { Write-Host '  状态：未安装' }
  Write-Host ''
  Write-Host '    1) 安装'
  Write-Host '    2) 更新'
  Write-Host '    3) 卸载'
  Write-Host ''
  $choice = Read-Host '  请选择 [1-3]'
  switch ($choice.Trim()) {
    '1' { $Action = 'install' }
    '2' { $Action = 'update' }
    '3' { $Action = 'uninstall' }
    default { Fail "没有这个选项：$choice"; return }
  }
  Write-Host ''
}
if ($Action -notin @('install', 'update', 'uninstall')) { Fail "未知操作：$Action"; return }
if ($Action -eq 'update' -and -not $Installed) { Warn '还没安装，改为执行安装'; $Action = 'install' }

# ---------- 进程 ----------
function Get-ProgramProcs($bin) {
  @(Get-CimInstance Win32_Process -Filter "Name='aistudio2api.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $bin })
}
function Stop-Program($bin) {
  $procs = Get-ProgramProcs $bin
  foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  for ($i = 0; $i -lt 10 -and (Get-ProgramProcs $bin).Count -gt 0; $i++) { Start-Sleep -Milliseconds 500 }
}
# Windows 拿不到别的进程的工作目录：命令行里带酒馆路径的优先，否则取唯一一个 node server.js
function Get-STProc {
  $nodes = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -match 'server\.js' })
  $exact = @($nodes | Where-Object { $_.CommandLine -like "*$StDir*" })
  if ($exact.Count -gt 0) { return $exact[0] }
  if ($nodes.Count -eq 1) { return $nodes[0] }
  return $null
}
function Start-ST {
  # 新开一个窗口跑酒馆，和平时双击 Start.bat 一样能看到输出
  Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', 'node server.js' -WorkingDirectory $StDir
}
function Test-PluginLoaded {
  for ($i = 0; $i -lt 40; $i++) {
    try {
      $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$StPort/api/plugins/aistudio2api/status"
      if ($r.Content -match '"status"') { Ok '验收通过：酒馆已加载 AIStudio2API 插件'; return $true }
    } catch {}
    Start-Sleep -Seconds 1
  }
  Warn '40 秒内没等到插件响应，看一下酒馆窗口里有没有报错'
  return $false
}

# ============================================
# 卸载
# ============================================
if ($Action -eq 'uninstall') {
  Write-Host '  将删除：'
  if (Test-Path $PluginDir) { Write-Host "    插件  $PluginDir" }
  if (Test-Path $ExtDir)    { Write-Host "    面板  $ExtDir" }
  if (Test-Path $AppDir)    { Write-Host '  下一步单独问：'; Write-Host "    程序与账号  $AppDir" }
  Write-Host ''
  if (-not (Test-Path $PluginDir) -and -not (Test-Path $ExtDir) -and -not (Test-Path $AppDir)) { Warn '没有找到已安装的 AIStudio2API，无需卸载'; return }
  if ($Interactive -and -not (Ask '确认卸载？' 'n')) { Warn '已取消'; return }

  if ((Get-ProgramProcs $BinPath).Count -gt 0) { Info '停止 AIStudio2API'; Stop-Program $BinPath; Ok '已停止' }
  Remove-Item -Recurse -Force $PluginDir, $ExtDir -ErrorAction SilentlyContinue
  Ok '已删除插件和面板'
  Remove-Item -Force $LinkFile -ErrorAction SilentlyContinue

  if ((Test-Path $AppDir) -and ($AppDir -ne $DefaultDir)) {
    Ok "已保留你独立安装的 ${AppDir}（插件只是借用它，不删）"
  } elseif (Test-Path $AppDir) {
    Write-Host ''
    Write-Host "  ${AppDir} 里有程序和已导入的 Google 账号（auth\），删了要重新导入账号" -ForegroundColor Yellow
    if ($Interactive -and (Ask '连程序和账号一起删除？' 'n')) {
      Remove-Item -Recurse -Force $AppDir
      Ok "已删除 $AppDir"
    } else {
      Ok "已保留 ${AppDir}（重新安装后账号直接可用）"
    }
  }
  $st = Get-STProc
  if ($st -and $Interactive -and (Ask '重启酒馆让面板消失？' 'y')) {
    Stop-Process -Id $st.ProcessId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-ST
    Ok '酒馆已在新窗口重启'
  }
  Write-Host ''
  Write-Host '  ✓ 卸载完成' -ForegroundColor Green
  Write-Host "  重新安装：$OneLine"
  Write-Host ''
  return
}

# ============================================
# 安装 / 更新
# ============================================
Ok "酒馆目录：$StDir"
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail '找不到 node（酒馆本身需要它，先把酒馆装好）'; return }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { Fail '找不到 curl.exe（需要 Windows 10 1803 及以上）'; return }
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { Fail '找不到 tar.exe（需要 Windows 10 1803 及以上）'; return }

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("aistudio2api-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  # ---------- 插件 + 前端面板 ----------
  Info $(if ($Installed) { '更新插件' } else { '下载插件' })
  & curl.exe -fsSL $RepoZip -o (Join-Path $Tmp 'plugin.zip')
  if ($LASTEXITCODE -ne 0) { Fail '插件下载失败（GitHub 连不上？开梯子再试）'; return }
  Expand-Archive -Path (Join-Path $Tmp 'plugin.zip') -DestinationPath (Join-Path $Tmp 'plugin') -Force
  $src = Get-ChildItem (Join-Path $Tmp 'plugin') -Directory | Select-Object -First 1
  Remove-Item -Recurse -Force $PluginDir, $ExtDir -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $PluginDir, $ExtDir | Out-Null
  Copy-Item -Recurse -Force (Join-Path $src.FullName '*') $PluginDir
  Copy-Item -Recurse -Force (Join-Path $src.FullName 'extension\*') $ExtDir
  Ok "插件：plugins\$Name"
  Ok "面板：public\scripts\extensions\third-party\$Name"

  if (Test-Path $Config) {
    $text = Get-Content -Raw -Encoding UTF8 $Config
    if ($text -match '(?m)^enableServerPlugins:\s*true') {
      Ok 'enableServerPlugins 已开启'
    } else {
      Copy-Item $Config "$Config.bak" -Force
      if ($text -match '(?m)^enableServerPlugins:') {
        $text = [regex]::Replace($text, '(?m)^enableServerPlugins:.*$', 'enableServerPlugins: true')
      } else {
        $text = $text.TrimEnd() + "`nenableServerPlugins: true`n"
      }
      [IO.File]::WriteAllText($Config, $text, (New-Object Text.UTF8Encoding($false)))
      Ok '已开启 enableServerPlugins（原配置备份为 config.yaml.bak）'
    }
  } else {
    Warn '还没有 config.yaml（酒馆没启动过）：首次启动后把 enableServerPlugins 改成 true 再重启'
  }

  # ---------- 识别独立安装的 AIStudio2API ----------
  function Count-Accounts($d) { @(Get-ChildItem -Directory (Join-Path $d 'auth') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' }).Count }
  function Test-AppDir($d) { (Test-Path (Join-Path $d 'aistudio2api.exe')) -and ((Test-Path (Join-Path $d '.env')) -or (Test-Path (Join-Path $d 'auth'))) }
  if (-not $env:AISTUDIO2API_HOME) {
    $found = @()
    $found += @(Get-CimInstance Win32_Process -Filter "Name='aistudio2api.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ExecutablePath } | ForEach-Object { Split-Path $_.ExecutablePath })
    $found += @(Get-ChildItem -Path $HOME -Filter aistudio2api.exe -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notlike '*\plugins\*' } | ForEach-Object { $_.DirectoryName })
    $curAcc = if (Test-AppDir $AppDir) { Count-Accounts $AppDir } else { 0 }
    foreach ($cand in ($found | Sort-Object -Unique)) {
      if ($cand -eq $AppDir -or -not (Test-AppDir $cand)) { continue }
      $n = Count-Accounts $cand
      Write-Host ''
      Info "发现独立安装的 AIStudio2API：${cand}（${n} 个账号）"
      $def = if ($curAcc -eq 0 -and $n -gt 0) { 'y' } else { 'n' }
      if ($Interactive -and (Ask '让插件直接用它？（文件不动，原来的账号直接可用）' $def)) {
        [IO.File]::WriteAllText($LinkFile, $cand, (New-Object Text.UTF8Encoding($false)))
        $AppDir = $cand
        $BinPath = Join-Path $AppDir 'aistudio2api.exe'
        $VerFile = Join-Path $AppDir '.termux-version'
        $Current = if (Test-Path $VerFile) { (Get-Content $VerFile -TotalCount 1).Trim() } else { '' }
        Ok "插件改用 $AppDir"
        break
      }
    }
  }

  # ---------- 程序本体：先下载到临时目录，进程停了再换上 ----------
  $Tag = $null; $Src = $null
  foreach ($s in $Sources) {
    $u = & curl.exe -fsL -o NUL -w '%{url_effective}' "https://github.com/$s/releases/latest"
    if ($LASTEXITCODE -eq 0 -and $u -match '/tag/([^/?#]+)') { $Tag = $Matches[1]; $Src = $s; break }
  }
  $NewBin = $null
  if (-not $Tag) {
    if (Test-Path $BinPath) { Warn "查不到最新版本，沿用已装的 $Current" }
    else { Warn '查不到最新版本（GitHub 连不上？），程序会在面板第一次点 ▶ 时再下载' }
  } else {
    if ($Src -ne $Sources[0]) { Warn "上游不可用，改用备份 $Src" }
    if ($Tag -eq $Current -and (Test-Path $BinPath)) {
      Ok "AIStudio2API 程序已是最新 $Tag"
    } else {
      $pkg = "aistudio2api-$Tag-windows-amd64"
      Info "下载 AIStudio2API $Tag（约 35MB）"
      $got = $false
      foreach ($s in (@($Src) + $Sources)) {
        & curl.exe -fL --progress-bar "https://github.com/$s/releases/download/$Tag/$pkg.zip" -o (Join-Path $Tmp 'pkg.zip')
        if ($LASTEXITCODE -eq 0) {
          Expand-Archive -Path (Join-Path $Tmp 'pkg.zip') -DestinationPath (Join-Path $Tmp 'pkg') -Force
          $exe = Get-ChildItem (Join-Path $Tmp 'pkg') -Recurse -Filter aistudio2api.exe | Select-Object -First 1
          if ($exe) { $NewBin = $exe.FullName; $got = $true; break }
        }
        Warn "从 $s 下载失败，换下一个来源"
      }
      if (-not $got) { Warn '程序下载失败，面板第一次点 ▶ 时会再试' }
    }
  }
  function Swap-Program {
    if (-not $NewBin) { return }
    if ((Get-ProgramProcs $BinPath).Count -gt 0) { Warn 'AIStudio2API 正在运行，这次没换程序；在面板点 ■ 停掉后再选「更新」'; return }
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    Copy-Item -Force $NewBin $BinPath
    Set-Content -Path $VerFile -Value $Tag -Encoding ASCII
    $from = if ($Current) { "$Current → " } else { '' }
    Ok "程序：${AppDir}（$from$Tag）"
  }

  # ---------- 酒馆：重启/启动 + 验收 ----------
  $Verified = $false
  Write-Host ''
  $st = Get-STProc
  if ($st) {
    Warn "酒馆正在运行（PID $($st.ProcessId)），要重启才能用上新插件"
    if ($Interactive -and (Ask '现在自动重启酒馆？（会在新窗口重新打开）' 'y')) {
      Stop-Process -Id $st.ProcessId -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
      if ((Get-ProgramProcs $BinPath).Count -gt 0) { Info '停止插件之前启动的 AIStudio2API（重启后在面板点 ▶ 再开）'; Stop-Program $BinPath }
      Swap-Program
      Start-ST
      Info '酒馆已在新窗口启动，等待插件加载…'
      $Verified = Test-PluginLoaded
    } else {
      Swap-Program
      Warn '请手动重启酒馆'
    }
  } else {
    Swap-Program
    if ($Interactive -and (Ask '酒馆没在运行，现在启动它？（在新窗口打开）' 'y')) {
      Start-ST
      Info '酒馆已在新窗口启动，等待插件加载…'
      $Verified = Test-PluginLoaded
    } else {
      Warn '下次启动酒馆后生效'
    }
  }

  Write-Host ''
  if ($Verified) {
    $what = if ($Action -eq 'update') { '更新' } else { '安装' }
    Write-Host "  ✓ ${what}成功" -ForegroundColor Green
  } else {
    Write-Host '  ! 已完成，重启酒馆后生效' -ForegroundColor Yellow
  }
  Write-Host ''
  Write-Host "  打开酒馆 http://127.0.0.1:$StPort → 扩展栏里的蓝色「AIStudio2API」面板"
  Write-Host '    ▶ 启动 / ■ 停止；「打开管理页面」添加账号'
  Write-Host '  接入：API 连接 → Chat Completion → 来源 Google AI Studio → 反向代理选「AIStudio2API」'
  Write-Host ''
  Write-Host '  以后更新、卸载：再运行同一条命令，选 2 或 3'
  Write-Host ''
} finally {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
}
