#!/bin/bash
set -e

REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
INSTANCE_TYPE="c7a.2xlarge"
VPC_NAME="XMRig-Mining-VPC"
JOB_NAME="xmrig-mining-job"

# Tạo VPC
echo "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$VPC_NAME
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}"

# Tạo Internet Gateway
echo "Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# Tạo Subnet
echo "Creating Subnet..."
AZ=$(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[0].ZoneName' --output text)
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone "$AZ" \
  --query 'Subnet.SubnetId' \
  --output text)

# Tạo Route Table
echo "Configuring Route Table..."
ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --subnet-id $SUBNET_ID --route-table-id $ROUTE_TABLE_ID

# Tạo Security Group
echo "Creating Security Group..."
SG_ID=$(aws ec2 create-security-group \
  --group-name "XMRig-SecurityGroup" \
  --description "Security group for XMRig mining" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0

# Tạo IAM Roles
echo "Creating IAM Roles..."

# ECS Task Execution Role
aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ecs-tasks.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}' > /dev/null

aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# AWS Batch Service Role
aws iam create-role --role-name AWSBatchServiceRole --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "batch.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}' > /dev/null

aws iam attach-role-policy \
  --role-name AWSBatchServiceRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole

# EC2 Instance Role
aws iam create-role --role-name ecsInstanceRole --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}' > /dev/null

aws iam attach-role-policy \
  --role-name ecsInstanceRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

aws iam create-instance-profile --role-name ecsInstanceRole

# Tạo Compute Environment
echo "Creating Compute Environment..."
COMPUTE_ENV_ARN=$(aws batch create-compute-environment \
  --compute-environment-name xmrig-compute-env \
  --type MANAGED \
  --state ENABLED \
  --compute-resources "{
    \"type\": \"EC2\",
    \"minvCpus\": 0,
    \"maxvCpus\": 8,
    \"desiredvCpus\": 0,
    \"instanceTypes\": [\"$INSTANCE_TYPE\"],
    \"subnets\": [\"$SUBNET_ID\"],
    \"securityGroupIds\": [\"$SG_ID\"],
    \"instanceRole\": \"ecsInstanceRole\",
    \"tags\": {\"Name\": \"XMRig-Miner\"},
    \"bidPercentage\": 100,
    \"spotIamFleetRole\": \"arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetRole\"
  }" \
  --service-role "arn:aws:iam::$ACCOUNT_ID:role/AWSBatchServiceRole" \
  --query 'computeEnvironmentArn' \
  --output text)

echo "Waiting for Compute Environment to become VALID..."
while true; do
  STATUS=$(aws batch describe-compute-environments \
    --compute-environments $COMPUTE_ENV_ARN \
    --query 'computeEnvironments[0].status' \
    --output text)
  
  if [ "$STATUS" = "VALID" ]; then
    break
  elif [ "$STATUS" = "INVALID" ]; then
    echo "Compute Environment creation failed!"
    exit 1
  fi
  sleep 10
done

# Tạo Job Queue
echo "Creating Job Queue..."
JOB_QUEUE_ARN=$(aws batch create-job-queue \
  --job-queue-name xmrig-queue \
  --state ENABLED \
  --priority 1 \
  --compute-environment-order order=1,computeEnvironment=$COMPUTE_ENV_ARN \
  --query 'jobQueueArn' \
  --output text)

# Tạo Job Definition
echo "Creating Job Definition..."
JOB_DEF_ARN=$(aws batch register-job-definition \
  --job-definition-name xmrig-job-definition \
  --type container \
  --container-properties "{
    \"image\": \"alpine\",
    \"vcpus\": 8,
    \"memory\": 16384,
    \"command\": [
      \"sh\", \"-c\",
      \"apk add --no-cache wget tar && wget https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-linux-static-x64.tar.gz && tar -xvf xmrig-6.22.2-linux-static-x64.tar.gz && ./xmrig -o xmr-eu.kryptex.network:7029 -u 88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV/LM64-28-3 -k --coin monero -a rx/8\"
    ]
  }" \
  --retry-strategy attempts=1 \
  --timeout attemptDurationSeconds=86400 \
  --query 'jobDefinitionArn' \
  --output text)

# Gửi Job
echo "Submitting Job..."
JOB_ID=$(aws batch submit-job \
  --job-name $JOB_NAME \
  --job-queue $JOB_QUEUE_ARN \
  --job-definition $JOB_DEF_ARN \
  --query 'jobId' \
  --output text)

echo "Job submitted successfully!"
echo "Job ID: $JOB_ID"
echo "You can monitor the job with:"
echo "aws batch describe-jobs --jobs $JOB_ID"

# Xuất thông tin cần thiết
echo "export VPC_ID=$VPC_ID" > cleanup_vars.sh
echo "export IGW_ID=$IGW_ID" >> cleanup_vars.sh
echo "export SUBNET_ID=$SUBNET_ID" >> cleanup_vars.sh
echo "export ROUTE_TABLE_ID=$ROUTE_TABLE_ID" >> cleanup_vars.sh
echo "export SG_ID=$SG_ID" >> cleanup_vars.sh
echo "export COMPUTE_ENV_ARN=$COMPUTE_ENV_ARN" >> cleanup_vars.sh
echo "export JOB_QUEUE_ARN=$JOB_QUEUE_ARN" >> cleanup_vars.sh
echo "export JOB_DEF_ARN=$JOB_DEF_ARN" >> cleanup_vars.sh

echo "Setup completed! To clean up resources later, run './cleanup_resources.sh'"
