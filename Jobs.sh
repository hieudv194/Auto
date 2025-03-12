#!/bin/bash

AWS_REGION="us-east-2"  # Thay đổi nếu cần
VPC_NAME="MiningVPC"
SUBNET_CIDR="10.0.1.0/24"
SECURITY_GROUP_NAME="MiningSecurityGroup"
COMPUTE_ENV="mining-c7a-batch-ce"
JOB_QUEUE="mining-c7a-batch-queue"
JOB_DEFINITION="mining-c7a-batch-job"
JOB_NAME="mining-xmr-c7a"
INSTANCE_TYPE="c7a.16xlarge"
MONERO_POOL="xmr-eu.kryptex.network:7029"
WALLET_ADDRESS="88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV"  # 🔥 THAY ĐỊA CHỈ VÍ MONERO CỦA BẠN
IAM_ROLE="arn:aws:iam::account-id:role/AWSBatchServiceRole"

echo "🚀 Bắt đầu thiết lập AWS Batch để đào Monero..."

# 1️⃣ Tạo VPC nếu chưa có
VPC_ID=$(aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)
if [[ "$VPC_ID" == "None" ]]; then
    echo "⚠️ Không tìm thấy VPC, đang tạo mới..."
    VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
    aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$VPC_NAME
fi
echo "✅ VPC ID: $VPC_ID"

# 2️⃣ Tạo Subnet nếu chưa có
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text)
if [[ "$SUBNET_ID" == "None" ]]; then
    echo "⚠️ Không tìm thấy Subnet, đang tạo mới..."
    SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR --query 'Subnet.SubnetId' --output text)
fi
echo "✅ Subnet ID: $SUBNET_ID"

# 3️⃣ Tạo Security Group nếu chưa có
SECURITY_GROUP=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$SECURITY_GROUP" == "None" ]]; then
    echo "⚠️ Không tìm thấy Security Group, đang tạo mới..."
    SECURITY_GROUP=$(aws ec2 create-security-group --group-name $SECURITY_GROUP_NAME --description "Mining security group" --vpc-id $VPC_ID --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP --protocol tcp --port 22 --cidr 0.0.0.0/0
    aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP --protocol tcp --port 10128 --cidr 0.0.0.0/0
fi
echo "✅ Security Group ID: $SECURITY_GROUP"

# 4️⃣ Tạo Compute Environment
aws batch create-compute-environment --region $AWS_REGION \
    --compute-environment-name $COMPUTE_ENV \
    --type MANAGED \
    --state ENABLED \
    --compute-resources type=EC2,minvCpus=0,maxvCpus=64,desiredvCpus=64,instanceTypes=["$INSTANCE_TYPE"],subnets=["$SUBNET_ID"],securityGroupIds=["$SECURITY_GROUP"],instanceRole="arn:aws:iam::account-id:instance-profile/AmazonEC2ContainerServiceforBatchRole" \
    --service-role "$IAM_ROLE"

# 5️⃣ Tạo Job Queue
aws batch create-job-queue --region $AWS_REGION \
    --job-queue-name $JOB_QUEUE \
    --state ENABLED \
    --priority 1 \
    --compute-environment-order order=1,computeEnvironment=$COMPUTE_ENV

# 6️⃣ Đăng ký Job Definition để đào Monero
aws batch register-job-definition --region $AWS_REGION \
    --job-definition-name $JOB_DEFINITION \
    --type container \
    --container-properties '{
        "image": "xmrig/xmrig",
        "vcpus": 64,
        "memory": 128000,
        "command": ["-o", "'"$MONERO_POOL"'", "-u", "'"$WALLET_ADDRESS"'", "-p", "c7a-batch"],
        "jobRoleArn": "'"$IAM_ROLE"'"
    }'

# 7️⃣ Gửi Job đào coin
JOB_ID=$(aws batch submit-job --region $AWS_REGION \
    --job-name $JOB_NAME \
    --job-queue $JOB_QUEUE \
    --job-definition $JOB_DEFINITION --query 'jobId' --output text)

echo "✅ Đã gửi Job đào Monero trên AWS Batch. Job ID: $JOB_ID"

# 8️⃣ Theo dõi job và tự động restart nếu bị dừng
while true; do
    STATUS=$(aws batch describe-jobs --jobs $JOB_ID --query 'jobs[0].status' --output text)
    
    if [[ "$STATUS" == "SUCCEEDED" || "$STATUS" == "FAILED" ]]; then
        echo "⚠️ Job đã dừng! Đang khởi động lại..."
        JOB_ID=$(aws batch submit-job --region $AWS_REGION \
            --job-name $JOB_NAME \
            --job-queue $JOB_QUEUE \
            --job-definition $JOB_DEFINITION --query 'jobId' --output text)
        echo "🔄 Đã gửi lại Job ID mới: $JOB_ID"
    fi
    
    echo "⏳ Job đang chạy... ($STATUS)"
    sleep 300  # Kiểm tra lại sau 5 phút
done
