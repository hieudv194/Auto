#!/bin/bash

# Dừng script ngay lập tức nếu có lỗi
set -e
# Phát hiện biến chưa được khai báo
set -u

# Danh sách các region và AMI ID tương ứng (Windows Server)
declare -A region_image_map=(
    ["us-east-1"]="ami-001adaa5c3ee02e10"
    ["us-east-2"]="ami-0b041308c8b9767f3"
    ["us-west-2"]="ami-0a1f75c71aceb9a3f"
)

# Tạo file PowerShell script (Duol-LM64.ps1)
user_data_file="/tmp/Duol-LM64.ps1"
cat << 'EOF' > "$user_data_file"
# Duol-LM64.ps1
# Script để tải xuống, giải nén và chạy XMRig (Windows) để đào Monero

# Đường dẫn tải xuống XMRig (Windows)
$xmrigUrl = "https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-gcc-win64.zip"
$xmrigZipFile = "xmrig-6.22.2-gcc-win64.zip"
$xmrigDir = "xmrig-6.22.2-gcc-win64"

# Thư mục làm việc
$workingDir = "C:\Miner"
if (-not (Test-Path -Path $workingDir)) {
    New-Item -ItemType Directory -Path $workingDir | Out-Null
}
Set-Location -Path $workingDir

# Tải xuống XMRig
Write-Output "Đang tải xuống XMRig..."
Invoke-WebRequest -Uri $xmrigUrl -OutFile $xmrigZipFile

# Kiểm tra xem file đã tải xuống thành công chưa
if (-not (Test-Path -Path $xmrigZipFile)) {
    Write-Output "Lỗi: Không thể tải xuống XMRig."
    exit 1
}

# Giải nén file zip (sử dụng Expand-Archive)
Write-Output "Đang giải nén XMRig..."
Expand-Archive -Path $xmrigZipFile -DestinationPath $workingDir -Force

# Kiểm tra xem thư mục XMRig đã được giải nén chưa
if (-not (Test-Path -Path "$workingDir\$xmrigDir")) {
    Write-Output "Lỗi: Không thể giải nén XMRig."
    exit 1
}

# Chạy XMRig với cấu hình đào Monero
Write-Output "Đang khởi chạy XMRig..."
Set-Location -Path "$workingDir\$xmrigDir"

# Cấu hình đào Monero
$poolUrl = "xmr-eu.kryptex.network:7029"
$walletAddress = "88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV/LM64-test2"
$algo = "rx/64"

# Chạy XMRig
Start-Process -FilePath ".\xmrig.exe" -ArgumentList "-o $poolUrl -u $walletAddress -k --coin monero -a $algo" -NoNewWindow

Write-Output "XMRig đã được khởi chạy thành công!"
EOF

# Kiểm tra xem file User Data có tồn tại không
if [ ! -s "$user_data_file" ]; then
    echo "Lỗi: Không thể tạo file User Data."
    exit 1
fi

# Mã hóa User Data sang base64
user_data_base64=$(base64 -w 0 "$user_data_file")

# Iterate over each region
for region in "${!region_image_map[@]}"; do
    echo "Processing region: $region"
    
    # Lấy AMI ID cho region
    image_id=${region_image_map[$region]}

    # Kiểm tra Key Pair
    key_name="WindowsKeyPair-$region"
    if aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" > /dev/null 2>&1; then
        echo "Key Pair $key_name đã tồn tại trong $region"
    else
        aws ec2 create-key-pair \
            --key-name "$key_name" \
            --region "$region" \
            --query "KeyMaterial" \
            --output text > "${key_name}.pem"
        chmod 400 "${key_name}.pem"
        echo "Đã tạo Key Pair $key_name trong $region"
    fi

    # Kiểm tra Security Group
    sg_name="Windows-SG-$region"
    sg_id=$(aws ec2 describe-security-groups --group-names "$sg_name" --region "$region" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)

    if [ -z "$sg_id" ]; then
        sg_id=$(aws ec2 create-security-group \
            --group-name "$sg_name" \
            --description "Security group cho Windows instances trong $region" \
            --region "$region" \
            --query "GroupId" \
            --output text)
        echo "Đã tạo Security Group $sg_name với ID $sg_id trong $region"
    else
        echo "Security Group $sg_name đã tồn tại với ID $sg_id trong $region"
    fi

    # Mở cổng RDP (3389) nếu chưa có
    if ! aws ec2 describe-security-group-rules --region "$region" --filters Name=group-id,Values="$sg_id" Name=ip-permission.from-port,Values=3389 Name=ip-permission.to-port,Values=3389 Name=ip-permission.cidr,Values=0.0.0.0/0 > /dev/null 2>&1; then
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --protocol tcp \
            --port 3389 \
            --cidr 0.0.0.0/0 \
            --region "$region"
        echo "Đã mở cổng RDP (3389) cho Security Group $sg_name trong $region"
    else
        echo "Cổng RDP (3389) đã được mở cho Security Group $sg_name trong $region"
    fi

    # Chọn Subnet ID tự động
    subnet_id=$(aws ec2 describe-subnets --region "$region" --query "Subnets[0].SubnetId" --output text)

    if [ -z "$subnet_id" ]; then
        echo "Không tìm thấy Subnet khả dụng trong $region. Bỏ qua region này."
        continue
    fi

    echo "Sử dụng Subnet ID $subnet_id trong $region"

    # Khởi chạy 1 Instance EC2 On-Demand (Loại t2.large, User Data chưa chạy)
    instance_id=$(aws ec2 run-instances \
        --image-id "$image_id" \
        --count 1 \
        --instance-type c7a.2xlarge \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --subnet-id "$subnet_id" \
        --user-data "$user_data_base64" \
        --region "$region" \
        --query "Instances[0].InstanceId" \
        --output text)

    if [ -z "$instance_id" ]; then
        echo "Lỗi: Không thể tạo instance trong $region."
        continue
    fi

    echo "Đã tạo Instance $instance_id trong $region với Key Pair $key_name và Security Group $sg_name"
done

# Xóa file tạm thời
rm -f "$user_data_file"

echo "Hoàn thành khởi tạo EC2 instances!"
