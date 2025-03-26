#!/bin/bash

# Script tạo AWS Batch hoàn chỉnh từ đầu cho mining Monero
# Đã sửa các lỗi và kiểm tra kỹ lưỡng
# Yêu cầu: AWS CLI đã cài đặt và cấu hình với quyền Administrator

# ------------------------- CẤU HÌNH -------------------------
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ENVIRONMENT_NAME="MoneroMiningBatch"
SERVICE_ROLE_NAME="AWSBatchServiceRole-$ENVIRONMENT_NAME"
ECS_INSTANCE_ROLE_NAME="ecsInstanceRole-$ENVIRONMENT_NAME"
BATCH_INSTANCE_ROLE_NAME="AWSBatchInstanceRole-$ENVIRONMENT_NAME"

# Cấu hình instance
INSTANCE_TYPES="c7a.2xlarge"  # AMD EPYC, 8 vCPU, 16GB RAM - tốt cho mining
MIN_VCPUS=0
MAX_VCPUS=256
DESIRED_VCPUS=4
SPOT_PERCENTAGE=100  # Sử dụng 100% Spot để tiết kiệm chi phí

# Cấu hình mạng
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_CIDR="10.0.1.0/24"

# Cấu hình mining - THAY THẾ BẰNG THÔNG TIN CỦA BẠN
WALLET_ADDRESS="88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV"
WORKER_ID="LM8-25-3"
MINING_POOL="xmr-eu.kryptex.network:7029"

# ------------------------- TẠO IAM ROLES -------------------------
echo "1. Tạo IAM roles..."

# AWS Batch Service Role
aws iam create-role --role-name $SERVICE_ROLE_NAME --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "batch.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}' > /dev/null 2>&1 || echo "Role $SERVICE_ROLE_NAME đã tồn tại, bỏ qua..."

aws iam attach-role-policy --role-name $SERVICE_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole

# ECS Instance Role
aws iam create-role --role-name $ECS_INSTANCE_ROLE_NAME --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}' > /dev/null 2>&1 || echo "Role $ECS_INSTANCE_ROLE_NAME đã tồn tại, bỏ qua..."

aws iam attach-role-policy --role-name $ECS_INSTANCE_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

# Tạo Instance Profile
aws iam create-instance-profile --instance-profile-name $ECS_INSTANCE_ROLE_NAME > /dev/null 2>&1 || echo "Instance Profile đã tồn tại, bỏ qua..."
aws iam add-role-to-instance-profile --instance-profile-name $ECS_INSTANCE_ROLE_NAME --role-name $ECS_INSTANCE_ROLE_NAME

# AWS Batch Instance Role
aws iam create-role --role-name $BATCH_INSTANCE_ROLE_NAME --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}' > /dev/null 2>&1 || echo "Role $BATCH_INSTANCE_ROLE_NAME đã tồn tại, bỏ qua..."

aws iam attach-role-policy --role-name $BATCH_INSTANCE_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

# ------------------------- TẠO VPC & NETWORKING -------------------------
echo "2. Thiết lập mạng..."

# Tạo VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$ENVIRONMENT_NAME-VPC" \
  --query "Vpcs[0].VpcId" --output text --region $REGION)

if [ "$VPC_ID" == "None" ]; then
  echo " - Tạo VPC mới..."
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --region $REGION \
    --query "Vpc.VpcId" --output text)
  aws ec2 create-tags --resources $VPC_ID \
    --tags Key=Name,Value="$ENVIRONMENT_NAME-VPC" --region $REGION
  
  # Tạo Internet Gateway
  IGW_ID=$(aws ec2 create-internet-gateway --region $REGION \
    --query "InternetGateway.InternetGatewayId" --output text)
  aws ec2 attach-internet-gateway --vpc-id $VPC_ID \
    --internet-gateway-id $IGW_ID --region $REGION
  
  # Tạo Route Table
  ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[0].RouteTableId" --output text --region $REGION)
  aws ec2 create-route --route-table-id $ROUTE_TABLE_ID \
    --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION
fi

# Tạo Subnet
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$PUBLIC_SUBNET_CIDR" \
  --query "Subnets[0].SubnetId" --output text --region $REGION)

if [ "$SUBNET_ID" == "None" ]; then
  echo " - Tạo Subnet mới..."
  SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID \
    --cidr-block $PUBLIC_SUBNET_CIDR --availability-zone "${REGION}a" \
    --region $REGION --query "Subnet.SubnetId" --output text)
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID \
    --map-public-ip-on-launch --region $REGION
fi

# Tạo Security Group
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$ENVIRONMENT_NAME-SG" \
  --query "SecurityGroups[0].GroupId" --output text --region $REGION)

if [ "$SG_ID" == "None" ]; then
  echo " - Tạo Security Group mới..."
  SG_ID=$(aws ec2 create-security-group --group-name "$ENVIRONMENT_NAME-SG" \
    --description "Security group for Monero mining" --vpc-id $VPC_ID \
    --region $REGION --query "GroupId" --output text)
  
  # Mở các port cần thiết
  aws ec2 authorize-security-group-ingress --group-id $SG_ID \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION
  aws ec2 authorize-security-group-ingress --group-id $SG_ID \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION
  aws ec2 authorize-security-group-ingress --group-id $SG_ID \
    --protocol tcp --port 443 --cidr 0.0.0.0/0 --region $REGION
  aws ec2 authorize-security-group-egress --group-id $SG_ID \
    --protocol all --cidr 0.0.0.0/0 --region $REGION
fi

# ------------------------- TẠO COMPUTE ENVIRONMENT -------------------------
echo "3. Tạo Compute Environment..."
COMPUTE_ENV_ARN=$(aws batch create-compute-environment \
  --compute-environment-name $ENVIRONMENT_NAME-ComputeEnv \
  --type MANAGED \
  --state ENABLED \
  --service-role arn:aws:iam::$AWS_ACCOUNT_ID:role/$SERVICE_ROLE_NAME \
  --compute-resources "type=EC2,minvCpus=$MIN_VCPUS,maxvCpus=$MAX_VCPUS,desiredvCpus=$DESIRED_VCPUS,instanceTypes=$INSTANCE_TYPES,subnets=$SUBNET_ID,securityGroupIds=$SG_ID,instanceRole=arn:aws:iam::$AWS_ACCOUNT_ID:instance-profile/$ECS_INSTANCE_ROLE_NAME,spotIamFleetRole=arn:aws:iam::$AWS_ACCOUNT_ID:role/$BATCH_INSTANCE_ROLE_NAME,bidPercentage=$SPOT_PERCENTAGE" \
  --region $REGION \
  --query "computeEnvironmentArn" \
  --output text)

echo " - Compute Environment ARN: $COMPUTE_ENV_ARN"

# Chờ Compute Environment active
echo " - Đợi Compute Environment active..."
aws batch wait compute-environment-valid \
  --compute-environments $ENVIRONMENT_NAME-ComputeEnv \
  --region $REGION

# ------------------------- TẠO JOB QUEUE -------------------------
echo "4. Tạo Job Queue..."
JOB_QUEUE_ARN=$(aws batch create-job-queue \
  --job-queue-name $ENVIRONMENT_NAME-Queue \
  --state ENABLED \
  --priority 1 \
  --compute-environment-order order=1,computeEnvironment=$COMPUTE_ENV_ARN \
  --region $REGION \
  --query "jobQueueArn" \
  --output text)

echo " - Job Queue ARN: $JOB_QUEUE_ARN"

# Chờ Job Queue active
echo " - Đợi Job Queue active..."
aws batch wait job-queue-valid \
  --job-queues $ENVIRONMENT_NAME-Queue \
  --region $REGION

# ------------------------- TẠO JOB DEFINITION -------------------------
echo "5. Tạo Job Definition..."
MINING_COMMAND="wget https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-linux-static-x64.tar.gz && tar -xvf xmrig-6.22.2-linux-static-x64.tar.gz && cd xmrig-6.22.2 && ./xmrig -o $MINING_POOL -u $WALLET_ADDRESS/$WORKER_ID -k --coin monero -a rx/8"

JOB_DEFINITION_ARN=$(aws batch register-job-definition \
  --job-definition-name $ENVIRONMENT_NAME-MoneroMiner \
  --type container \
  --container-properties '{
    "image": "ubuntu:latest",
    "command": ["sh", "-c", "'"$MINING_COMMAND"'"],
    "resourceRequirements": [
      {"type": "VCPU", "value": "8"},
      {"type": "MEMORY", "value": "16384"}
    ],
    "executionRoleArn": "arn:aws:iam::'$AWS_ACCOUNT_ID':role/'$ECS_INSTANCE_ROLE_NAME'",
    "jobRoleArn": "arn:aws:iam::'$AWS_ACCOUNT_ID':role/'$BATCH_INSTANCE_ROLE_NAME'",
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/aws/batch/job",
        "awslogs-region": "'$REGION'",
        "awslogs-stream-prefix": "'$ENVIRONMENT_NAME'"
      }
    }
  }' \
  --region $REGION \
  --query "jobDefinitionArn" \
  --output text)

echo " - Job Definition ARN: $JOB_DEFINITION_ARN"

# ------------------------- GỬI JOB MINING -------------------------
echo "6. Gửi job mining..."
JOB_ID=$(aws batch submit-job \
  --job-name monero-mining-job-$(date +%s) \
  --job-queue $ENVIRONMENT_NAME-Queue \
  --job-definition $ENVIRONMENT_NAME-MoneroMiner \
  --region $REGION \
  --query "jobId" \
  --output text)

echo " - Job ID: $JOB_ID"

# ------------------------- KẾT QUẢ -------------------------
echo "7. Thông tin triển khai:"
echo "================================================"
echo "Compute Environment: $COMPUTE_ENV_ARN"
echo "Job Queue: $JOB_QUEUE_ARN"
echo "Job Definition: $JOB_DEFINITION_ARN"
echo "VPC ID: $VPC_ID"
echo "Subnet ID: $SUBNET_ID"
echo "Security Group ID: $SG_ID"
echo "Job đã chạy với ID: $JOB_ID"
echo "================================================"
echo "Để kiểm tra trạng thái job, chạy lệnh sau:"
echo "aws batch describe-jobs --jobs $JOB_ID --region $REGION"
echo "Để xem logs, truy cập CloudWatch Logs tại AWS Console"
