#!/bin/bash
set -e

# Config
REGION="us-west-2"
INSTANCE_TYPE="c6a.xlarge"
VPC_NAME="XMRig-Mining-VPC"
JOB_NAME="xmrig-mining-job"
YOUR_WALLET_ADDRESS="88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV" # THAY ĐỔI thành ví của bạn!

# Lấy Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Tạo VPC
echo "1. Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$VPC_NAME
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}"

# Tạo Internet Gateway
echo "2. Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# Lấy AZ khả dụng đầu tiên
AZ=$(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[0].ZoneName' --output text)

# Tạo Subnet
echo "3. Creating Subnet in AZ $AZ..."
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone $AZ \
  --query 'Subnet.SubnetId' \
  --output text)

# Tạo Route Table
echo "4. Configuring Route Table..."
ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --subnet-id $SUBNET_ID --route-table-id $ROUTE_TABLE_ID

# Tạo Security Group
echo "5. Creating Security Group..."
SG_ID=$(aws ec2 create-security-group \
  --group-name "XMRig-SecurityGroup" \
  --description "Security group for XMRig mining" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

# Tạo IAM Roles
echo "6. Creating IAM Roles..."

# AWS Batch Service Role
BATCH_SERVICE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/AWSBatchServiceRole"
if ! aws iam get-role --role-name AWSBatchServiceRole &> /dev/null; then
    aws iam create-role \
        --role-name AWSBatchServiceRole \
        --assume-role-policy-document '{
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
    echo " - Created AWSBatchServiceRole"
else
    echo " - AWSBatchServiceRole already exists"
fi

# EC2 Instance Role
ECS_INSTANCE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ecsInstanceRole"
if ! aws iam get-role --role-name ecsInstanceRole &> /dev/null; then
    aws iam create-role \
        --role-name ecsInstanceRole \
        --assume-role-policy-document '{
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
    echo " - Created ecsInstanceRole"
else
    echo " - ecsInstanceRole already exists"
fi

# Instance Profile
if ! aws iam get-instance-profile --instance-profile-name ecsInstanceProfile &> /dev/null; then
    aws iam create-instance-profile --instance-profile-name ecsInstanceProfile > /dev/null
    aws iam add-role-to-instance-profile \
        --instance-profile-name ecsInstanceProfile \
        --role-name ecsInstanceRole
    echo " - Created ecsInstanceProfile"
    sleep 10  # Chờ IAM propagate
else
    echo " - ecsInstanceProfile already exists"
fi

# Tạo Compute Environment
echo "7. Creating Compute Environment..."
COMPUTE_ENV_ARN=$(aws batch create-compute-environment \
  --compute-environment-name xmrig-compute-env \
  --type MANAGED \
  --state ENABLED \
  --compute-resources "{
    \"type\": \"EC2\",
    \"minvCpus\": 0,
    \"maxvCpus\": 4,
    \"desiredvCpus\": 0,
    \"instanceTypes\": [\"$INSTANCE_TYPE\"],
    \"subnets\": [\"$SUBNET_ID\"],
    \"securityGroupIds\": [\"$SG_ID\"],
    \"instanceRole\": \"ecsInstanceRole\",
    \"tags\": {\"Name\": \"XMRig-Miner\"}
  }" \
  --service-role "$BATCH_SERVICE_ROLE_ARN" \
  --query 'computeEnvironmentArn' \
  --output text)

echo " - Waiting for Compute Environment to become VALID..."
while true; do
  STATUS=$(aws batch describe-compute-environments \
    --compute-environments $COMPUTE_ENV_ARN \
    --query 'computeEnvironments[0].status' \
    --output text)
  
  if [ "$STATUS" = "VALID" ]; then
    break
  elif [ "$STATUS" = "INVALID" ]; then
    echo " ! Compute Environment creation failed!"
    exit 1
  fi
  sleep 10
done

# Tạo Job Queue
echo "8. Creating Job Queue..."
JOB_QUEUE_ARN=$(aws batch create-job-queue \
  --job-queue-name xmrig-queue \
  --state ENABLED \
  --priority 1 \
  --compute-environment-order order=1,computeEnvironment=$COMPUTE_ENV_ARN \
  --query 'jobQueueArn' \
  --output text)

# Tạo Job Definition
echo "9. Creating Job Definition..."
JOB_DEF_ARN=$(aws batch register-job-definition \
  --job-definition-name xmrig-job-definition \
  --type container \
  --container-properties "{
    \"image\": \"alpine\",
    \"vcpus\": 4,
    \"memory\": 8384,
    \"command\": [
      \"sh\", \"-c\",
      \"apk add --no-cache wget tar && wget https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-linux-static-x64.tar.gz && tar -xvf xmrig-6.22.2-linux-static-x64.tar.gz && ./xmrig -o xmr-eu.kryptex.network:7029 -u $YOUR_WALLET_ADDRESS/test -k --coin monero -a rx/8\"
    ]
  }" \
  --retry-strategy attempts=1 \
  --timeout attemptDurationSeconds=86400 \
  --query 'jobDefinitionArn' \
  --output text)

# Gửi Job
echo "10. Submitting Job..."
JOB_ID=$(aws batch submit-job \
  --job-name $JOB_NAME \
  --job-queue $JOB_QUEUE_ARN \
  --job-definition $JOB_DEF_ARN \
  --query 'jobId' \
  --output text)

echo "=============================================="
echo "XMRig Mining Job deployed successfully!"
echo "Job ID: $JOB_ID"
echo "Monitor with: aws batch describe-jobs --jobs $JOB_ID"
echo "=============================================="
