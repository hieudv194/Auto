#!/bin/bash
# Script AWS Batch On-Demand c7a.2xlarge cho Monero Mining
# Version: 3.1 - Sửa lỗi IAM Role & Job Definition

# ---------------------- CẤU HÌNH ----------------------
REGION="us-west-2"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ENVIRONMENT_NAME="XMR-OnDemand-c7a"
INSTANCE_TYPES="c7a.2xlarge"

# Giới hạn tài nguyên để kiểm soát chi phí
MIN_VCPUS=8
MAX_VCPUS=8
DESIRED_VCPUS=8

# Cấu hình mining (THAY ĐỔI THÔNG TIN CỦA BẠN)
WALLET_ADDRESS="88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV"
WORKER_ID="AWS-OnDemand-Miner"
MINING_POOL="xmr-eu.kryptex.network:7029"

# ---------------------- KIỂM TRA AWS CLI ----------------------
if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI chưa được cài đặt!"
    exit 1
fi

# ---------------------- TẠO IAM ROLES ----------------------
echo "1. Thiết lập IAM Roles..."

create_iam_role() {
    local role_name=$1
    local policy_arn=$2
    local trust_policy=$3
    
    if ! aws iam get-role --role-name $role_name &> /dev/null; then
        echo " - Tạo IAM Role $role_name..."
        aws iam create-role --role-name $role_name \
            --assume-role-policy-document "$trust_policy"
        aws iam attach-role-policy --role-name $role_name \
            --policy-arn $policy_arn
    else
        echo " - IAM Role $role_name đã tồn tại, bỏ qua..."
    fi
}

create_iam_role "AWSBatchServiceRole-$ENVIRONMENT_NAME" \
    "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole" \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"batch.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

create_iam_role "ecsInstanceRole-$ENVIRONMENT_NAME" \
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role" \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if ! aws iam get-instance-profile --instance-profile-name "ecsInstanceRole-$ENVIRONMENT_NAME" &> /dev/null; then
    echo " - Tạo Instance Profile..."
    aws iam create-instance-profile --instance-profile-name "ecsInstanceRole-$ENVIRONMENT_NAME"
    aws iam add-role-to-instance-profile --instance-profile-name "ecsInstanceRole-$ENVIRONMENT_NAME" --role-name "ecsInstanceRole-$ENVIRONMENT_NAME"
fi

# ---------------------- TẠO COMPUTE ENVIRONMENT ----------------------
echo "2. Tạo Compute Environment..."
COMPUTE_ENV_ARN=$(aws batch create-compute-environment \
    --compute-environment-name "$ENVIRONMENT_NAME-ComputeEnv" \
    --type MANAGED \
    --state ENABLED \
    --service-role "arn:aws:iam::$AWS_ACCOUNT_ID:role/AWSBatchServiceRole-$ENVIRONMENT_NAME" \
    --compute-resources "type=EC2,minvCpus=$MIN_VCPUS,maxvCpus=$MAX_VCPUS,desiredvCpus=$DESIRED_VCPUS,instanceTypes=$INSTANCE_TYPES,instanceRole=arn:aws:iam::$AWS_ACCOUNT_ID:instance-profile/ecsInstanceRole-$ENVIRONMENT_NAME,allocationStrategy=BEST_FIT" \
    --region $REGION \
    --query "computeEnvironmentArn" \
    --output text)

# ---------------------- TẠO JOB DEFINITION ----------------------
echo "3. Tạo Job Definition..."
MINING_COMMAND="wget https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-linux-static-x64.tar.gz && tar -xvf xmrig-6.22.2-linux-static-x64.tar.gz && cd xmrig-6.22.2 && ./xmrig -o $MINING_POOL -u $WALLET_ADDRESS/$WORKER_ID -k --coin monero -a rx/8"

JOB_DEFINITION_ARN=$(aws batch register-job-definition \
  --job-definition-name "$ENVIRONMENT_NAME-MoneroMiner" \
  --type container \
  --container-properties '{
    "image": "ubuntu:latest",
    "command": ["sh", "-c", "'$MINING_COMMAND'"],
    "resourceRequirements": [
      {"type": "VCPU", "value": "8"},
      {"type": "MEMORY", "value": "16384"}
    ],
    "executionRoleArn": "arn:aws:iam::'$AWS_ACCOUNT_ID':role/ecsInstanceRole-'$ENVIRONMENT_NAME'",
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

# ---------------------- GỬI JOB MINING ----------------------
echo "4. Khởi chạy Mining Job..."
JOB_ID=$(aws batch submit-job \
    --job-name "xmr-miner-$(date +%s)" \
    --job-queue "$ENVIRONMENT_NAME-Queue" \
    --job-definition "$JOB_DEFINITION_ARN" \
    --region $REGION \
    --query "jobId" \
    --output text)

echo "✅ Mining Job ID: $JOB_ID"
echo "🔍 Kiểm tra trạng thái: aws batch describe-jobs --jobs $JOB_ID --region $REGION"
echo "📊 Xem logs: https://$REGION.console.aws.amazon.com/cloudwatch/home?region=$REGION#logsV2:log-groups/log-group/$252Faws$252Fbatch$252Fjob"
