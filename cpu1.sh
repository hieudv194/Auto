#!/bin/bash

# Danh sách các vùng cần kiểm tra
REGIONS=("us-east-1" "us-west-2" "eu-west-3")

echo "📌 Kiểm tra hiệu suất CPU của các máy trong vùng: ${REGIONS[*]}"

# Lặp qua từng vùng
for REGION in "${REGIONS[@]}"; do
    echo "🔹 Vùng: $REGION"
    
    # Lấy danh sách tất cả các Instance đang chạy
    INSTANCE_IDS=$(aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=running" \
        --query "Reservations[*].Instances[*].InstanceId" --output text)

    if [ -z "$INSTANCE_IDS" ]; then
        echo "Không có máy nào đang chạy trong vùng $REGION."
        continue
    fi

    # Lặp qua từng instance để lấy hiệu suất CPU
    for INSTANCE_ID in $INSTANCE_IDS; do
        CPU_UTILIZATION=$(aws cloudwatch get-metric-statistics --region $REGION \
            --namespace AWS/EC2 --metric-name CPUUtilization --dimensions Name=InstanceId,Value=$INSTANCE_ID \
            --statistics Average --period 300 --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
            --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --query "Datapoints[*].Average" --output text)
        
        if [ -z "$CPU_UTILIZATION" ]; then
            CPU_UTILIZATION="No Data"
        fi

        echo "🔹 Instance: $INSTANCE_ID | CPU Usage: $CPU_UTILIZATION%"
    done
done
