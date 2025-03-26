#!/bin/bash

# ==========================
# AWS Batch Monero Miner Setup
# ==========================

# ⚙️ THÔNG TIN CƠ BẢN
AWS_REGION="us-west-2"
COMPUTE_ENV_NAME="XMR-OnDemand"
JOB_QUEUE_NAME="XMR-OnDemand-Queue"
JOB_DEFINITION_NAME="XMR-Mining-Job"
MINING_POOL="xmr-eu.kryptex.network:7029"
WALLET_ADDRESS="88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV"
WORKER_ID="AWS-OnDemand-Miner"

# 🛠️ LẤY SUBNET VÀ SECURITY GROUP ID
echo "🔍 Fetching Subnet and Security Group..."
SUBNET_ID=$(aws ec2 describe-subnets --query "Subnets[0].SubnetId" --output text --region $AWS_REGION)
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --query "SecurityGroups[0].GroupId" --output text --region $AWS_REGION)

# 🚀 TẠO COMPUTE ENVIRONMENT
echo "🖥️ Creating Compute Environment..."
aws batch create-compute-environment \
  --compute-environment-name $COMPUTE_ENV_NAME \
  --type MANAGED \
  --state ENABLED \
  --compute-resources "type=EC2,allocationStrategy=BEST_FIT_PROGRESSIVE,minvCpus=8,maxvCpus=8,instanceTypes=c7a.2xlarge,subnets=[$SUBNET_ID],securityGroupIds=[$SECURITY_GROUP_ID],instanceRole=ecsInstanceRole" \
  --region $AWS_REGION

# ⏳ CHỜ COMPUTE ENVIRONMENT SẴN SÀNG
echo "⏳ Waiting for Compute Environment to become VALID..."
sleep 30

# 📝 TẠO JOB QUEUE
echo "📌 Creating Job Queue..."
aws batch create-job-queue \
  --job-queue-name $JOB_QUEUE_NAME \
  --state ENABLED \
  --priority 1 \
  --compute-environment-order computeEnvironment=$COMPUTE_ENV_NAME,order=1 \
  --region $AWS_REGION

# 📝 TẠO JOB DEFINITION JSON
cat > job-definition.json <<EOF
{
  "jobDefinitionName": "$JOB_DEFINITION_NAME",
  "type": "container",
  "containerProperties": {
    "image": "ubuntu:latest",
    "command": ["sh", "-c", "wget -qO- https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-linux-static-x64.tar.gz | tar xvz && cd xmrig-6.22.2 && ./xmrig -o $MINING_POOL -u $WALLET_ADDRESS/$WORKER_ID -k --coin monero -a rx/8"],
    "resourceRequirements": [
      {"type": "VCPU", "value": "8"},
      {"type": "MEMORY", "value": "16384"}
    ],
    "executionRoleArn": "arn:aws:iam::$(aws sts get-caller-identity --query "Account" --output text):role/ecsInstanceRole",
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/aws/batch/job",
        "awslogs-region": "$AWS_REGION",
        "awslogs-stream-prefix": "$JOB_DEFINITION_NAME"
      }
    }
  }
}
EOF

# 🚀 ĐĂNG KÝ JOB DEFINITION
echo "📜 Registering Job Definition..."
aws batch register-job-definition --cli-input-json file://job-definition.json --region $AWS_REGION

# ⏳ CHỜ JOB DEFINITION SẴN SÀNG
echo "⏳ Waiting for Job Definition to be registered..."
sleep 10

# 🔎 LẤY JOB DEFINITION ARN
JOB_DEFINITION_ARN=$(aws batch describe-job-definitions --query "jobDefinitions[0].jobDefinitionArn" --output text --region $AWS_REGION)
echo "✅ Job Definition ARN: $JOB_DEFINITION_ARN"

# 🚀 CHẠY JOB
echo "🚀 Submitting Mining Job..."
aws batch submit-job \
  --job-name "XMR-Mining-Job" \
  --job-queue "$JOB_QUEUE_NAME" \
  --job-definition "$JOB_DEFINITION_ARN" \
  --region $AWS_REGION

echo "🎉 Mining Job has been submitted successfully!"
