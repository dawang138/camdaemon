# 部署 camdaemon 到越狱 iPhone（root 公钥免密，同 WiFi）。
# 用法：
#   powershell -File deploy.ps1 -DeviceIp 192.168.2.11
# 前置：Win 公钥已写入手机 root 的 /var/jb/var/root/.ssh/authorized_keys。

param(
    [string]$DeviceIp = "192.168.2.11",
    [string]$User = "root",
    [string]$RemoteDir = "/var/jb/var/root/camdaemon"
)

$ErrorActionPreference = "Stop"
$sshOpts = @("-o","BatchMode=yes","-o","StrictHostKeyChecking=no")

$pkgDir = Join-Path $PSScriptRoot "..\packages"
$deb = Get-ChildItem (Join-Path $pkgDir "*.deb") -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $deb) {
    throw "未找到 deb 产物：请先在 GitHub Actions 编译，把 packages/*.deb 下载到本地 $pkgDir"
}

Write-Host "[1/4] 上传 $($deb.Name) -> $DeviceIp"
scp @sshOpts $deb.FullName "${User}@${DeviceIp}:/tmp/"

Write-Host "[2/4] 安装 deb（rootless dpkg）"
ssh @sshOpts "${User}@${DeviceIp}" "mkdir -p $RemoteDir && dpkg -i /tmp/$($deb.Name) || true"

Write-Host "[3/4] 加载 LaunchDaemon"
ssh @sshOpts "${User}@${DeviceIp}" @"
launchctl bootout system/com.local.camdaemon 2>/dev/null
launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.local.camdaemon.plist 2>/dev/null || launchctl load -w /var/jb/Library/LaunchDaemons/com.local.camdaemon.plist
"@

Write-Host "[4/4] 状态与日志"
ssh @sshOpts "${User}@${DeviceIp}" @"
sleep 1
launchctl list | grep -i camdaemon || echo 'daemon 未加载'
echo '----- log -----'
tail -20 /var/jb/var/log/camdaemon.log 2>/dev/null
tail -20 /var/jb/var/log/camdaemon.err.log 2>/dev/null
"@

Write-Host "完成。验证：http://$DeviceIp:8090/health.json"
