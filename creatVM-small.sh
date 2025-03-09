#!/bin/bash

# Định nghĩa các biến
declare -A region_image_map=(
    ["us-east-1"]="ami-0e2c8caa4b6378d8c"
    ["us-west-2"]="ami-05d38da78ce859165"
    ["us-east-2"]="ami-0cb91c7de36eed2cb"
)
instance_type="c7a.xlarge"
output_dir="/tmp/instance_info"  # Thư mục lưu thông tin instance
key_dir="/tmp/keys"  # Thư mục lưu file .pem

# Tạo thư mục lưu thông tin instance và file .pem
mkdir -p "$output_dir"
mkdir -p "$key_dir"

# Lặp qua từng vùng
for region in "${!region_image_map[@]}"; do
    echo "Processing region: $region"

    # Lấy AMI ID tương ứng với vùng
    image_id=${region_image_map[$region]}

    # Tạo Key Pair nếu chưa tồn tại
    key_name="keyname01-$region"
    key_file="$key_dir/$key_name.pem"

    if ! aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" > /dev/null 2>&1; then
        echo "Creating Key Pair $key_name in $region..."
        aws ec2 create-key-pair \
            --key-name "$key_name" \
            --region "$region" \
            --query "KeyMaterial" \
            --output text > "$key_file"
        chmod 400 "$key_file"
        echo "Key Pair $key_name created and saved to $key_file"
    else
        echo "Key Pair $key_name already exists in $region"
    fi

    # Tạo Security Group nếu chưa tồn tại
    sg_name="Random-$region"
    sg_id=$(aws ec2 describe-security-groups --group-names "$sg_name" --region "$region" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)

    if [ -z "$sg_id" ]; then
        echo "Creating Security Group $sg_name in $region..."
        sg_id=$(aws ec2 create-security-group \
            --group-name "$sg_name" \
            --description "Security group for $region" \
            --region "$region" \
            --query "GroupId" \
            --output text)
        echo "Security Group $sg_name created with ID $sg_id in $region"
    else
        echo "Security Group $sg_name already exists with ID $sg_id in $region"
    fi

    # Đảm bảo quy tắc SSH (port 22) được mở
    if ! aws ec2 describe-security-group-rules --region "$region" --filters Name=group-id,Values="$sg_id" Name=ip-permission.from-port,Values=22 Name=ip-permission.to-port,Values=22 Name=ip-permission.cidr,Values=0.0.0.0/0 > /dev/null 2>&1; then
        echo "Enabling SSH (port 22) access for Security Group $sg_name in $region..."
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region "$region"
        echo "SSH (port 22) access enabled for Security Group $sg_name in $region"
    else
        echo "SSH (port 22) access already configured for Security Group $sg_name in $region"
    fi

    # Tạo máy ảo với kiểu máy nhỏ
    echo "Creating instance with type $instance_type in $region..."
    instance_id=$(aws ec2 run-instances \
        --image-id "$image_id" \
        --count 1 \
        --instance-type "$instance_type" \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --region "$region" \
        --query "Instances[0].InstanceId" \
        --output text)

    echo "Instance $instance_id created with type $instance_type in $region"

    # Đợi instance chuyển sang trạng thái "running"
    echo "Waiting for instance $instance_id to be in running state..."
    aws ec2 wait instance-running \
        --instance-ids "$instance_id" \
        --region "$region"

    echo "Instance $instance_id is now running."

    # Lưu thông tin instance vào file
    output_file="$output_dir/instance_info_$region.txt"
    echo "Saving instance information to $output_file..."
    echo "instance_id=$instance_id" > "$output_file"
    echo "region=$region" >> "$output_file"
    echo "key_name=$key_name" >> "$output_file"
    echo "key_file=$key_file" >> "$output_file"  # Lưu đường dẫn file .pem
    echo "sg_id=$sg_id" >> "$output_file"

    echo "Small instance creation completed for region $region. Instance information saved to $output_file."
done

echo "All small instances created successfully."
