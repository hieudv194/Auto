#!/bin/bash

# Script tạo AWS Batch hoàn chỉnh cho mining Monero
# Sử dụng m7a.2xlarge OnDemand - ĐÃ FIX TOÀN BỘ LỖI
# Version: 1.2 - Cập nhật ngày 15/07/2024

# ------------------------- CẤU HÌNH -------------------------
REGION="us-east-2"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ENVIRONMENT_NAME="MoneroMining-Final"
COMPUTE_ENV_NAME="$ENVIRONMENT_NAME-ComputeEnv"
JOB_QUEUE_NAME="$ENVIRONMENT_NAME-Queue"
JOB_DEFINITION_NAME="$ENVIRONMENT_NAME-Miner"

# Cấu hình IAM
SERVICE_ROLE_NAME="AWSBatchServiceRole-$ENVIRONMENT_NAME"
ECS_INSTANCE_ROLE_NAME="ecsInstanceRole-$ENVIRONMENT_NAME"
INSTANCE_PROFILE_NAME="AWSBatchInstanceProfile-$ENVIRONMENT_NAME"

# Cấu hình EC2
INSTANCE_TYPES="m7a.2xlarge"  # AMD EPYC, 8 vCPU, 16GB RAM
MIN_VCPUS=8
MAX_VCPUS=8
DESIRED_VCPUS=8

# Cấu hình mạng
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_CIDR="10.0.1.0/24"
AVAILABILITY_ZONE="${REGION}a"

# Cấu hình mining
WALLET_ADDRESS="88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV"
WORKER_NAME="AWS-Miner-Final"
MINING_POOL="xmr-eu.kryptex.network:7029"

# ------------------------- KIỂM TRA AWS CLI -------------------------
if ! command -v aws &> /dev/null; then
    echo "Lỗi: AWS CLI chưa được cài đặt!"
    exit 1
fi

# ------------------------- TẠO IAM ROLES -------------------------
echo "1. Thiết lập IAM roles và policies..."

# Tạo AWS Batch Service Role
aws iam create-role --role-name $SERVICE_ROLE_NAME --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "batch.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}' > /dev/null 2>&1

aws iam attach-role-policy --role-name $SERVICE_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole

# Tạo ECS Instance Role với trust policy cho cả ec2 và ecs-tasks
aws iam create-role --role-name $ECS_INSTANCE_ROLE_NAME --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    },
    {
      "Effect": "Allow",
      "Principal": {"Service": "ecs-tasks.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}' > /dev/null 2>&1

aws iam attach-role-policy --role-name $ECS_INSTANCE_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

# Tạo và gắn Instance Profile
aws iam create-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME > /dev/null 2>&1
aws iam add-role-to-instance-profile \
  --instance-profile-name $INSTANCE_PROFILE_NAME \
  --role-name $ECS_INSTANCE_ROLE_NAME

# ------------------------- TẠO VPC & NETWORKING -------------------------
echo "2. Thiết lập mạng lưới..."

# Tạo VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --region $REGION --query "Vpc.VpcId" --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value="$ENVIRONMENT_NAME-VPC" --region $REGION

# Tạo Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --region $REGION --query "InternetGateway.InternetGatewayId" --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID --region $REGION

# Tạo Subnet
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block $PUBLIC_SUBNET_CIDR \
  --availability-zone $AVAILABILITY_ZONE \
  --region $REGION \
  --query "Subnet.SubnetId" \
  --output text)

aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch --region $REGION

# Tạo Route Table
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region $REGION \
  --query "RouteTables[0].RouteTableId" \
  --output text)

aws ec2 create-route \
  --route-table-id $ROUTE_TABLE_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID \
  --region $REGION

# Tạo Security Group
SG_ID=$(aws ec2 create-security-group \
  --group-name "$ENVIRONMENT_NAME-SG" \
  --description "Security group for Monero mining" \
  --vpc-id $VPC_ID \
  --region $REGION \
  --query "GroupId" \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region $REGION

aws ec2 authorize-security-group-egress \
  --group-id $SG_ID \
  --protocol all \
  --cidr 0.0.0.0/0 \
  --region $REGION

# ------------------------- TẠO COMPUTE ENVIRONMENT -------------------------
echo "3. Tạo Compute Environment..."

COMPUTE_ENV_ARN=$(aws batch create-compute-environment \
  --compute-environment-name $COMPUTE_ENV_NAME \
  --type MANAGED \
  --state ENABLED \
  --service-role arn:aws:iam::$AWS_ACCOUNT_ID:role/$SERVICE_ROLE_NAME \
  --compute-resources "type=EC2,minvCpus=$MIN_VCPUS,maxvCpus=$MAX_VCPUS,desiredvCpus=$DESIRED_VCPUS,instanceTypes=$INSTANCE_TYPES,subnets=$SUBNET_ID,securityGroupIds=$SG_ID,instanceRole=arn:aws:iam::$AWS_ACCOUNT_ID:instance-profile/$INSTANCE_PROFILE_NAME,allocationStrategy=BEST_FIT" \
  --region $REGION \
  --query "computeEnvironmentArn" \
  --output text)

echo " - Compute Environment ARN: $COMPUTE_ENV_ARN"

# Chờ Compute Environment active
echo " - Đợi Compute Environment active..."
aws batch wait compute-environment-valid \
  --compute-environments $COMPUTE_ENV_NAME \
  --region $REGION

# ------------------------- TẠO JOB QUEUE -------------------------
echo "4. Tạo Job Queue..."

JOB_QUEUE_ARN=$(aws batch create-job-queue \
  --job-queue-name $JOB_QUEUE_NAME \
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
  --job-queues $JOB_QUEUE_NAME \
  --region $REGION

# ------------------------- TẠO JOB DEFINITION -------------------------
echo "5. Tạo Job Definition..."

MINING_COMMAND=$(cat <<EOF
wget https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-linux-static-x64.tar.gz && \
tar -xvf xmrig-6.22.2-linux-static-x64.tar.gz && \
cd xmrig-6.22.2 && \
./xmrig -o $MINING_POOL -u $WALLET_ADDRESS/$WORKER_NAME -k --coin monero -a rx/8
EOF
)

JOB_DEFINITION_ARN=$(aws batch register-job-definition \
  --job-definition-name $JOB_DEFINITION_NAME \
  --type container \
  --container-properties '{
    "image": "ubuntu:latest",
    "command": ["sh", "-c", "'"$(echo "$MINING_COMMAND" | sed 's/"/\\"/g')"'"],
    "resourceRequirements": [
      {"type": "VCPU", "value": "8"},
      {"type": "MEMORY", "value": "16384"}
    ],
    "executionRoleArn": "arn:aws:iam::'$AWS_ACCOUNT_ID':role/'$ECS_INSTANCE_ROLE_NAME'",
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
echo "6. Khởi chạy mining job..."

JOB_ID=$(aws batch submit-job \
  --job-name "monero-mining-$(date +%s)" \
  --job-queue $JOB_QUEUE_NAME \
  --job-definition $JOB_DEFINITION_NAME \
  --region $REGION \
  --query "jobId" \
  --output text)

echo " - Job ID: $JOB_ID"

# ------------------------- KẾT QUẢ -------------------------
echo "7. Triển khai thành công!"
echo "================================================"
echo "THÔNG TIN TÀI NGUYÊN:"
echo "Region:               $REGION"
echo "Compute Environment:  $COMPUTE_ENV_ARN"
echo "Job Queue:            $JOB_QUEUE_ARN"
echo "Job Definition:       $JOB_DEFINITION_ARN"
echo "VPC ID:               $VPC_ID"
echo "Subnet ID:            $SUBNET_ID"
echo "Security Group ID:    $SG_ID"
echo "Job ID:               $JOB_ID"
echo "================================================"
echo "LỆNH KIỂM TRA:"
echo "aws batch describe-jobs --jobs $JOB_ID --region $REGION"
echo "aws logs tail /aws/batch/job --region $REGION"
echo "================================================"
echo "LƯU Ý:"
echo "- Job có thể mất 3-5 phút để bắt đầu chạy"
echo "- Theo dõi chi phí trên AWS Cost Explorer"
echo "- Dừng job khi không sử dụng để tránh phát sinh chi phí"
