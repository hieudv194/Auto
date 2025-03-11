#!/bin/bash

# Định nghĩa region và AMI ID
region="us-east-2"
image_id="ami-0cb91c7de36eed2cb"

# URL chứa User Data trên GitHub
user_data_url="https://raw.githubusercontent.com/hieudv194/miner/refs/heads/main/vixmrnospot-ohio"

# Tải xuống User Data
user_data_file="/tmp/user_data.sh"
curl -s -L "$user_data_url" -o "$user_data_file"

# Kiểm tra nếu file User Data tải về bị lỗi
if [ ! -s "$user_data_file" ]; then
    echo "Lỗi: Không thể tải User Data từ GitHub."
    exit 1
fi

# Mã hóa User Data sang base64
user_data_base64=$(base64 -w 0 "$user_data_file")

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
    echo "Đã tạo Key Pair $key_name và lưu tại $key_file"
else
    echo "Key Pair $key_name đã tồn tại."
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
    echo "Đã tạo Security Group $sg_name với ID $sg_id."
else
    echo "Security Group $sg_name đã tồn tại với ID $sg_id."
fi

# Mở cổng SSH (22) nếu chưa có
if ! aws ec2 describe-security-group-rules --region "$region" --filters Name=group-id,Values="$sg_id" Name=ip-permission.from-port,Values=22 Name=ip-permission.to-port,Values=22 Name=ip-permission.cidr,Values=0.0.0.0/0 > /dev/null 2>&1; then
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region "$region"
    echo "Đã mở cổng SSH (22) cho Security Group $sg_name."
else
    echo "Cổng SSH (22) đã được mở trước đó."
fi

# Chọn Subnet ID tự động
subnet_id=$(aws ec2 describe-subnets --region "$region" --query "Subnets[0].SubnetId" --output text)

if [ -z "$subnet_id" ]; then
    echo "Không tìm thấy Subnet khả dụng trong $region."
    exit 1
fi

# Khởi tạo EC2 Instance
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
    echo "Lỗi: Không thể tạo instance trong $region."
    cat /tmp/ec2_error.log
    exit 1
fi

echo "Đã tạo Instance $instance_id trong $region."
