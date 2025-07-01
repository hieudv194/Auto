#!/bin/bash

# Danh sách các region và AMI ID tương ứng
declare -A region_image_map=(
    ["us-east-1"]="ami-0e2c8caa4b6378d8c"
    ["us-west-2"]="ami-05d38da78ce859165"
)

# URL chứa User Data trên GitHub
user_data_url="https://raw.githubusercontent.com/hieudv194/Auto/refs/heads/main/Vixmr-LM64"

# Đường dẫn lưu User Data
user_data_file="/tmp/user_data.sh"

# Tải User Data từ GitHub
echo "Downloading user-data from GitHub..."
curl -s -L "$user_data_url" -o "$user_data_file"

# Kiểm tra xem tệp có tồn tại và không rỗng không
if [ ! -s "$user_data_file" ]; then
    echo "Error: Failed to download user-data from GitHub."
    exit 1
fi

# Encode User Data sang base64
user_data_base64=$(base64 -w 0 "$user_data_file")

# Duyệt qua từng region
for region in "${!region_image_map[@]}"; do
    echo "Processing region: $region"
    
    # Lấy AMI ID cho region
    image_id=${region_image_map[$region]}

    # Kiểm tra Key Pair
    key_name="KeyPair-$region"
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
    sg_name="Random-$region"
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

    # Mở cổng SSH (22) nếu chưa có
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

    # Chọn Subnet ID tự động
    subnet_id=$(aws ec2 describe-subnets --region "$region" --query "Subnets[0].SubnetId" --output text)

    if [ -z "$subnet_id" ]; then
        echo "Không tìm thấy Subnet khả dụng trong $region. Bỏ qua region này."
        continue
    fi

    echo "Sử dụng Subnet ID $subnet_id trong Auto Scaling Group của $region"

    ##================= TẠO INSTANCE SPOT (PERSISTENT) =================##
    spot_request_id=$(aws ec2 request-spot-instances \
        --instance-count 1 \
        --type "one-time" \
        --launch-specification "{
            \"ImageId\": \"$image_id\",
            \"InstanceType\": \"c7a.16xlarge\",
            \"KeyName\": \"$key_name\",
            \"SecurityGroupIds\": [\"$sg_id\"],
            \"SubnetId\": \"$subnet_id\",
            \"UserData\": \"$user_data_base64\"
        }" \
        --region "$region" \
        --query "SpotInstanceRequests[0].SpotInstanceRequestId" \
        --output text)

    echo "Yêu cầu Spot Instance (persistent) với ID: $spot_request_id đã được gửi trong $region"

done

echo "Hoàn thành khởi tạo EC2 instances!"
