#!/bin/bash

# Định nghĩa các biến
instance_type_large="c7a.2xlarge"
user_data_url="https://raw.githubusercontent.com/hieudv194/Auto/refs/heads/main/vixmr-lm8"
user_data_file="/tmp/user_data.sh"
input_dir="/tmp/instance_info"
log_dir="/tmp/logs"

mkdir -p "$log_dir"

# Tải User Data nếu chưa có
if [ ! -f "$user_data_file" ]; then
    echo "Downloading User Data..."
    curl -s -L "$user_data_url" -o "$user_data_file"
fi

if [ ! -s "$user_data_file" ]; then
    echo "Error: Failed to download User Data."
    exit 1
fi

user_data_base64=$(base64 -w 0 "$user_data_file")

declare -a regions=("us-east-1" "us-west-2" "us-east-2")

for region in "${regions[@]}"; do
    echo "Processing region: $region"
    input_file="$input_dir/instance_info_$region.txt"

    if [ ! -f "$input_file" ]; then
        echo "Error: Instance info not found for $region."
        continue
    fi

    source "$input_file"

    # Dừng instance
    echo "Stopping instance $instance_id..."
    aws ec2 stop-instances --instance-ids "$instance_id" --region "$region"
    aws ec2 wait instance-stopped --instance-ids "$instance_id" --region "$region"

    # Nâng cấp kiểu máy
    aws ec2 modify-instance-attribute --instance-id "$instance_id" --instance-type "$instance_type_large" --region "$region"

    # Khởi động lại instance
    aws ec2 start-instances --instance-ids "$instance_id" --region "$region"
    aws ec2 wait instance-running --instance-ids "$instance_id" --region "$region"

    # Lấy Public IP nếu chưa có
    if [ -z "$public_ip" ] || [ "$public_ip" == "None" ]; then
        for attempt in {1..5}; do
            public_ip=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
            if [ "$public_ip" != "None" ]; then
                echo "public_ip=$public_ip" >> "$input_file"
                break
            fi
            sleep 15
        done
    fi

    if [ "$public_ip" == "None" ]; then
        echo "Error: No Public IP found for $instance_id."
        continue
    fi

    # Kết nối SSH & Chạy miner
    for attempt in {1..5}; do
        echo "Attempting SSH connection ($attempt/5)..."
        ssh -i "$key_file" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@"$public_ip" "echo 'SSH is ready'" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "SSH is ready."
            break
        fi
        sleep 60
    done

    if [ $? -ne 0 ]; then
        echo "Error: SSH connection failed for $instance_id."
        continue
    fi

    echo "Running miner on instance $instance_id..."
    ssh -i "$key_file" -o StrictHostKeyChecking=no ec2-user@"$public_ip" "sudo bash /var/lib/cloud/instances/$instance_id/user-data.txt" > "$log_dir/ssh_log_$instance_id.txt" 2>&1

    echo "Miner started successfully on $instance_id."
done

echo "All instances upgraded & miner started successfully."
