#!/bin/bash

# Danh sách các region và AMI ID tương ứng
declare -A region_image_map=(
    ["us-east-1"]="ami-0e2c8caa4b6378d8c"
    ["us-west-2"]="ami-05d38da78ce859165"
    ["us-east-2"]="ami-0cb91c7de36eed2cb"
)

# URL chứa User Data trên GitHub
user_data_url="https://raw.githubusercontent.com/hieudv194/miner/refs/heads/main/vixmrnospot-ohio"

# File chứa User Data
user_data_file="/tmp/user_data.sh"

# Tải User Data từ GitHub
echo "Downloading user-data from GitHub..."
curl -s -L "$user_data_url" -o "$user_data_file"

# Kiểm tra file
if [ ! -s "$user_data_file" ]; then
    echo "Error: Failed to download user-data from GitHub."
    exit 1
fi

# Bổ sung lệnh chạy lại User Data vào file
echo -e "\n# Ensure User Data Runs on Reboot" >> "$user_data_file"
echo -e "echo 'User Data Script is Running' >> /var/log/user_data.log" >> "$user_data_file"
echo -e "bash /var/lib/cloud/instance/scripts/part-001" >> "$user_data_file"

# Mã hóa User Data thành base64
user_data_base64=$(base64 -w 0 "$user_data_file")

# Hàm khởi chạy instance trong một region
launch_instance() {
    local region="$1"
    local image_id="${region_image_map[$region]}"
    local key_name="Key00-$region"
    local sg_name="Random-$region"

    echo "Processing region: $region"

    # Kiểm tra & tạo Key Pair
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

    # Kiểm tra & tạo Security Group
    sg_id=$(aws ec2 describe-security-groups --group-names "$sg_name" --region "$region" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
    if [ -z "$sg_id" ]; then
        sg_id=$(aws ec2 create-security-group \
            --group-name "$sg_name" \
            --description "Security group cho $region" \
            --region "$region" \
            --query "GroupId" \
            --output text)
        echo "Đã tạo Security Group $sg_name với ID $sg_id trong $region"
    else
        echo "Security Group $sg_name đã tồn tại với ID $sg_id trong $region"
    fi

    # Mở cổng SSH nếu chưa có
    if ! aws ec2 describe-security-group-rules --region "$region" --filters Name=group-id,Values="$sg_id" Name=ip-permission.from-port,Values=22 Name=ip-permission.to-port,Values=22 Name=ip-permission.cidr,Values=0.0.0.0/0 > /dev/null 2>&1; then
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region "$region"
        echo "Đã mở cổng SSH (22) cho Security Group $sg_name trong $region"
    else
        echo "Cổng SSH (22) đã được mở cho Security Group $sg_name trong $region"
    fi

    # Lấy Subnet ID
    subnet_id=$(aws ec2 describe-subnets --region "$region" --query "Subnets[0].SubnetId" --output text)
    if [ -z "$subnet_id" ]; then
        echo "Không tìm thấy Subnet khả dụng trong $region. Bỏ qua region này."
        return
    fi

    echo "Sử dụng Subnet ID $subnet_id trong $region"

    # Khởi chạy EC2 Instance
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
        --output text)

    echo "Đã tạo Instance $instance_id trong $region với Key Pair $key_name và Security Group $sg_name"
}

# Chạy instance đầu tiên ngay
launch_instance "us-east-2"

# Chờ 24h trước khi chạy tiếp các region còn lại
echo "Đợi 24 giờ trước khi khởi chạy các instance còn lại..."
sleep 86400

# Chạy các instance còn lại
launch_instance "us-east-1"
launch_instance "us-west-2"

echo "Hoàn thành khởi tạo EC2 instances!"
