#!/bin/bash

# Định nghĩa các biến
instance_type_large="c7a.2xlarge"
user_data_url="https://raw.githubusercontent.com/hieudv194/Auto/refs/heads/main/vixmr-lm8"
input_dir="/tmp/instance_info"  # Thư mục chứa thông tin instance
log_dir="/tmp/logs"  # Thư mục lưu log
ssh_timeout=60  # Thời gian chờ SSH sẵn sàng

# Tạo thư mục lưu log
mkdir -p "$log_dir"

# Định nghĩa danh sách các vùng
declare -a regions=("us-east-1" "us-west-2" "us-east-2")

# Lặp qua từng vùng
for region in "${regions[@]}"; do
    echo "Processing region: $region"

    # Đường dẫn đến file thông tin instance của vùng
    input_file="$input_dir/instance_info_$region.txt"

    # Kiểm tra xem file thông tin instance có tồn tại không
    if [ ! -f "$input_file" ]; then
        echo "Error: Instance information file $input_file not found for region $region."
        continue
    fi

    # Đọc thông tin instance từ file
    source "$input_file"

    # Dừng instance để nâng cấp kiểu máy
    echo "Stopping instance $instance_id for resizing..."
    aws ec2 stop-instances --instance-ids "$instance_id" --region "$region"
    aws ec2 wait instance-stopped --instance-ids "$instance_id" --region "$region"
    echo "Instance $instance_id is now stopped."

    # Thay đổi kiểu máy thành c7a.2xlarge
    echo "Changing instance type to $instance_type_large..."
    aws ec2 modify-instance-attribute --instance-id "$instance_id" --instance-type "{\"Value\": \"$instance_type_large\"}" --region "$region"
    echo "Instance $instance_id has been resized to $instance_type_large."

    # Khởi động lại instance
    echo "Starting instance $instance_id..."
    aws ec2 start-instances --instance-ids "$instance_id" --region "$region"
    aws ec2 wait instance-running --instance-ids "$instance_id" --region "$region"
    echo "Instance $instance_id is now running with type $instance_type_large."

    # Lấy địa chỉ IP public của instance
    public_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$region" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text)

    # Kiểm tra nếu instance có địa chỉ IP công khai
    if [ "$public_ip" == "None" ]; then
        echo "Error: Instance $instance_id does not have a public IP."
        continue
    fi

    echo "Public IP of instance $instance_id: $public_ip"

    # Chờ đợi để SSH sẵn sàng
    echo "Waiting for SSH to be available (up to $ssh_timeout seconds)..."
    sleep $ssh_timeout

    # Kiểm tra kết nối SSH
    ssh -i "$key_file" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@"$public_ip" "echo 'SSH is ready'" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Error: SSH connection failed for instance $instance_id."
        continue
    fi

    # Tải lại User Data từ GitHub và chạy nó
    echo "Running User Data on instance $instance_id..."
    ssh -i "$key_file" -o StrictHostKeyChecking=no ec2-user@"$public_ip" "curl -s -L $user_data_url | sudo bash" > "$log_dir/ssh_log_$instance_id.txt" 2>&1

    # Kiểm tra và chạy miner
    echo "Checking if miner is installed..."
    ssh -i "$key_file" -o StrictHostKeyChecking=no ec2-user@"$public_ip" "
        if ! command -v xmrig &> /dev/null; then
            echo 'Miner not found, installing...'
            sudo yum update -y
            sudo yum install -y git cmake gcc gcc-c++ make libuv-devel openssl-devel hwloc-devel
            git clone https://github.com/xmrig/xmrig.git /home/ec2-user/xmrig
            cd /home/ec2-user/xmrig
            mkdir build && cd build
            cmake ..
            make -j$(nproc)
            echo 'Miner installed successfully.'
        fi
        echo 'Starting miner...'
        nohup /home/ec2-user/xmrig/build/xmrig --donate-level=1 --cpu-priority=5 --threads=$(nproc) > /dev/null 2>&1 &
        echo 'Miner started successfully.'
    " > "$log_dir/miner_log_$instance_id.txt" 2>&1

    echo "User Data and miner executed successfully on instance $instance_id in region $region."
done

echo "All instances upgraded, User Data executed, and miner started successfully."
