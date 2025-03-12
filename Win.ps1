# Bật logging để debug
Start-Transcript -Path C:\Windows\Temp\setup.log -Append

# Tạo thư mục làm việc
$workDir = "C:\Windows\Temp\xmrig"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
Set-Location -Path $workDir

# Tải và giải nén XMRig
$xmrigUrl = "https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-msvc-win64.zip"
Invoke-WebRequest -Uri $xmrigUrl -OutFile "$workDir\xmrig.zip"
Expand-Archive -Path "$workDir\xmrig.zip" -DestinationPath $workDir -Force
Remove-Item "$workDir\xmrig.zip"

# Cấu hình XMRig với Worker Name động (theo EC2 Instance ID)
$instanceID = (Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/instance-id)
$workerName = "Worker-$instanceID"

$xmrigConfig = @"
{
    "autosave": true,
    "cpu": true,
    "opencl": false,
    "cuda": false,
    "pools": [
        {
            "url": "xmr-eu.kryptex.network:7029",
            "user": "88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV.$workerName",
            "keepalive": true,
            "tls": false
        }
    ]
}
"@
$xmrigConfig | Out-File -Encoding utf8 "$workDir\config.json"

# Chạy XMRig ngay lập tức (hiện cửa sổ)
Start-Process -FilePath "$workDir\xmrig.exe" -ArgumentList "--config=$workDir\config.json"

# Thêm XMRig vào Startup để tự chạy khi bật máy
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty -Path $runKey -Name "XMRig" -Value "$workDir\xmrig.exe --config=$workDir\config.json"

# Tắt logging
Stop-Transcript
