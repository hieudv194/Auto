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

# Tạo key pair nếu chưa tồn tại
create_keypair() {
    local region=$1
    local key_name="MyCustomKeyPair-$region"
    if ! aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" > /dev/null 2>&1; then
        echo "Tạo KeyPair: $key_name trong vùng $region"
        aws ec2 create-key-pair \
            --key-name "$key_name" \
            --region "$region" \
            --query "KeyMaterial" \
            --output text > "${key_name}.pem"
        chmod 400 "${key_name}.pem"
    fi
}

# Tạo file user_data để khởi động XMRig trên Windows instance
cat << 'EOF' > user_data_script.ps1
powershell -NoProfile -ExecutionPolicy Bypass -Command "& {
    $workDir = 'C:\XMRig';
    if (-Not (Test-Path $workDir)) {
        New-Item -ItemType Directory -Path $workDir | Out-Null
    }
    Set-Location -Path $workDir

    # Đường dẫn tải xuống XMRig
    $xmrigUrl = 'https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-gcc-win64.zip'
    $xmrigZip = "$workDir\xmrig-6.22.2.zip"
    $xmrigDir = "$workDir\xmrig-6.22.2-gcc"

    # Tải xuống XMRig
    if (-Not (Test-Path $xmrigZip)) {
        Invoke-WebRequest -Uri $xmrigUrl -OutFile $xmrigZip
    }

    # Giải nén nếu thư mục chưa tồn tại
    if (-Not (Test-Path $xmrigDir)) {
        Expand-Archive -Path $xmrigZip -DestinationPath $workDir -Force
    }

    # Thêm vào Task Scheduler để chạy khi hệ thống khởi động
    $taskName = 'StartXMRig'
    $taskAction = New-ScheduledTaskAction -Execute "$xmrigDir\xmrig.exe" -Argument "-o xmr-eu.kryptex.network:7029 -u 88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV.myworker -k --coin monero -a rx/64"
    $taskTrigger = New-ScheduledTaskTrigger -AtStartup
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet
    $task = New-ScheduledTask -Action $taskAction -Principal $taskPrincipal -Trigger $taskTrigger -Settings $taskSettings
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force
}"
EOF

# Mã hóa user_data thành Base64
user_data_base64=$(base64 -w 0 user_data_script.ps1)

# Khởi tạo các phiên bản EC2...
for region in "${!region_image_map[@]}"; do
    echo "Đang xử lý region: $region"
    
    image_id=${region_image_map[$region]}
    key_name="MyCustomKeyPair"
    key_path="${key_name}.pem"
    
    # Kiểm tra và tạo key pair nếu chưa có
    create_keypair "$region"
    
    security_group_name="${region}_security_group"
    
    # Tạo security group nếu chưa tồn tại
    if ! aws ec2 describe-security-groups --region "$region" --group-names "$security_group_name" &> /dev/null; then
        echo "Tạo Security Group trong $region"
        sg_id=$(aws ec2 create-security-group \
            --group-name "$security_group_name" \
            --description "Security group cho MyCustom miner" \
            --region "$region" \
            --query "GroupId" \
            --output text)
        
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --protocol tcp \
            --port 3389 \
            --cidr 0.0.0.0/0 \
            --region "$region"
        echo "Đã mở cổng RDP (3389) cho Security Group $security_group_name"
    else
        sg_id=$(aws ec2 describe-security-groups \
            --region "$region" \
            --filters Name=group-name,Values="$security_group_name" \
            --query "SecurityGroups[0].GroupId" \
            --output text)
    fi
    
    echo "Sử dụng Security Group ID $sg_id trong $region"
    
    # Lấy subnet ID
    subnet_id=$(aws ec2 describe-subnets --region "$region" --query "Subnets[0].SubnetId" --output text)
    if [ -z "$subnet_id" ]; then
        echo "Không tìm thấy Subnet ID, bỏ qua $region"
        continue
    fi
    echo "Sử dụng Subnet ID $subnet_id trong $region"

    # Khởi chạy instance với user-data Base64
    instance_id=$(aws ec2 run-instances \
        --image-id "$image_id" \
        --count 1 \
        --instance-type "c7a.2xlarge" \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --subnet-id "$subnet_id" \
        --user-data "$user_data_base64" \
        --region "$region" \
        --query "Instances[0].InstanceId" \
        --output text)
    
    echo "Tạo instance thành công: $instance_id trong $region"
done
