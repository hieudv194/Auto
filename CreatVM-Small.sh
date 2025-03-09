#!/bin/bash

# Định nghĩa các biến
declare -A region_image_map=(
    ["us-east-1"]="ami-0e2c8caa4b6378d8c"
    ["us-west-2"]="ami-05d38da78ce859165"
    ["us-east-2"]="ami-0cb91c7de36eed2cb"
)
instance_type="c7a.xlarge"
output_dir="/tmp/instance_info"
key_dir="/tmp/keys"

# Tạo thư mục lưu thông tin instance và file .pem
mkdir -p "$output_dir"
mkdir -p "$key_dir"

for region in "${!region_image_map[@]}"; do
    echo "Processing region: $region"

    # Lấy AMI ID
    image_id=${region_image_map[$region]}

    # Tạo Key Pair
    key_name="keypair01-$region"
    key_file="$key_dir/$key_name.pem"

    if ! aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" > /dev/null 2>&1; then
        echo "Creating Key Pair $key_name in $region..."
        aws ec2 create-key-pair --key-name "$key_name" --region "$region" --query "KeyMaterial" --output text > "$key_file"
        chmod 400 "$key_file"
    fi

    # Tạo Security Group
    sg_name="Random-$region"
    sg_id=$(aws ec2 describe-security-groups --group-names "$sg_name" --region "$region" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)

    if [ -z "$sg_id" ]; then
        echo "Creating Security Group..."
        sg_id=$(aws ec2 create-security-group --group-name "$sg_name" --description "Security group for $region" --region "$region" --query "GroupId" --output text)
    fi

    # Mở cổng SSH nếu chưa mở
    if ! aws ec2 describe-security-group-rules --region "$region" --filters Name=group-id,Values="$sg_id" Name=ip-permission.from-port,Values=22 Name=ip-permission.to-port,Values=22 Name=ip-permission.cidr,Values=0.0.0.0/0 > /dev/null 2>&1; then
        aws ec2 authorize-security-group-ingress --group-id "$sg_id" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$region"
    fi

    # Tạo Instance Nhỏ
    echo "Creating instance in $region..."
    instance_id=$(aws ec2 run-instances --image-id "$image_id" --count 1 --instance-type "$instance_type" --key-name "$key_name" --security-group-ids "$sg_id" --region "$region" --query "Instances[0].InstanceId" --output text)

    if [ -z "$instance_id" ]; then
        echo "Error: Failed to create instance in $region."
        continue
    fi

    # Đợi instance chạy
    aws ec2 wait instance-running --instance-ids "$instance_id" --region "$region"

    # Lấy Public IP
    public_ip=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

    # Lưu thông tin vào file
    output_file="$output_dir/instance_info_$region.txt"
    echo "instance_id=$instance_id" > "$output_file"
    echo "region=$region" >> "$output_file"
    echo "key_name=$key_name" >> "$output_file"
    echo "key_file=$key_file" >> "$output_file"
    echo "sg_id=$sg_id" >> "$output_file"
    echo "ami_id=$image_id" >> "$output_file"
    echo "instance_type=$instance_type" >> "$output_file"
    echo "public_ip=$public_ip" >> "$output_file"

    echo "Instance $instance_id created successfully in $region."
done

echo "All small instances created successfully."
