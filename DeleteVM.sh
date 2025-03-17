#!/bin/bash

# Danh sách các vùng cần xóa máy
REGIONS=("us-east-1" "us-east-2" "us-west-2")

echo "📌 Đang xóa tất cả EC2 instances trong các vùng: ${REGIONS[*]}"

# Lặp qua từng vùng
for REGION in "${REGIONS[@]}"; do
    echo "🔹 Kiểm tra vùng: $REGION"
    
    # Lấy danh sách tất cả các instances đang chạy
    INSTANCE_IDS=$(aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=running" \
        --query "Reservations[*].Instances[*].InstanceId" --output text)

    if [ -z "$INSTANCE_IDS" ]; then
        echo "✅ Không có máy nào đang chạy trong vùng $REGION."
        continue
    fi

    # Hiển thị danh sách các máy sẽ bị xóa
    echo "🛑 Các máy sẽ bị xóa: $INSTANCE_IDS"
    
    # Xóa (terminate) tất cả các máy
    aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_IDS
    echo "✅ Đã gửi yêu cầu xóa các máy trong vùng $REGION."
done

echo "🎯 Hoàn thành!"
