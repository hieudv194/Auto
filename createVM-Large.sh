#!/bin/bash

# Định nghĩa các biến
instance_type_large="c7a.16xlarge"
user_data_url="https://raw.githubusercontent.com/hieudv194/Auto/refs/heads/main/vixmr-lm8"
user_data_file="/tmp/user_data.sh"
input_dir="/tmp/instance_info"  # Thư mục chứa thông tin instance

# Tải User Data từ GitHub nếu file không tồn tại
if [ ! -f "$user_data_file" ]; then
    echo "Downloading User Data from GitHub..."
    curl -s -L "$user_data_url" -o "$user_data_file"
fi

# Kiểm tra xem file User Data có tồn tại và không rỗng không
if [ ! -s "$user_data_file" ]; then
    echo "Error: Failed to download User Data from GitHub."
    exit 1
fi

# Mã hóa User Data sang base64
user_data_base64=$(base64 -w 0 "$user_data_file")

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
    aws ec2 stop-instances \
        --instance-ids "$instance_id" \
        --region "$region"

    # Đợi instance chuyển sang trạng thái "stopped"
    aws ec2 wait instance-stopped \
        --instance-ids "$instance_id" \
        --region "$region"

    echo "Instance $instance_id is now stopped."

    # Thay đổi kiểu máy thành c7a.2xlarge
    echo "Changing instance type to $instance_type_large..."
    aws ec2 modify-instance-attribute \
        --instance-id "$instance_id" \
        --instance-type "$instance_type_large" \
        --region "$region"

    echo "Instance $instance_id has been resized to $instance_type_large."

    # Khởi động lại instance
    echo "Starting instance $instance_id..."
    aws ec2 start-instances \
        --instance-ids "$instance_id" \
        --region "$region"

    # Đợi instance chuyển sang trạng thái "running"
    aws ec2 wait instance-running \
        --instance-ids "$instance_id" \
        --region "$region"

    echo "Instance $instance_id is now running with type $instance_type_large."

    # Cập nhật User Data
    echo "Updating User Data for instance $instance_id..."
    aws ec2 modify-instance-attribute \
        --instance-id "$instance_id" \
        --user-data "$user_data_base64" \
        --region "$region"

    echo "User Data has been updated for instance $instance_id."

    # Lấy địa chỉ IP public của instance
    public_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$region" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text)

    echo "Public IP of instance $instance_id is $public_ip"

    # Chờ đợi để đảm bảo instance sẵn sàng nhận kết nối SSH
    echo "Waiting for SSH to be available..."
    sleep 60  # Đợi 60 giây để instance khởi động hoàn toàn

    # Kết nối SSH và chạy User Data
    echo "Running User Data on instance $instance_id..."
    ssh -i "$key_file" -o StrictHostKeyChecking=no ec2-user@"$public_ip" "sudo bash /var/lib/cloud/instances/$instance_id/user-data.txt"

    echo "User Data executed successfully on instance $instance_id in region $region."
done

echo "All instances upgraded and User Data executed successfully."
