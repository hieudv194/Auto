#!/bin/bash
# Script AWS Batch On-Demand c7a.2xlarge cho Monero Mining
# Version: 3.0 - Hoàn chỉnh với xử lý lỗi và kiểm tra trạng thái

# ---------------------- CẤU HÌNH ----------------------
REGION="us-west-2"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ENVIRONMENT_NAME="XMR-OnDemand-c7a"
INSTANCE_TYPES="c7a.2xlarge"  # AMD EPYC 7th Gen, 8 vCPU, 16GB RAM

# Giới hạn tài nguyên để kiểm soát chi phí
MIN_VCPUS=8
MAX_VCPUS=8
DESIRED_VCPUS=8

# Cấu hình mạng
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_CIDR="10.0.1.0/24"

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

echo "1. Thiết lập IAM Roles..."

# AWS Batch Service Role
create_iam_role "AWSBatchServiceRole-$ENVIRONMENT_NAME" \
    "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole" \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"batch.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# EC2 Instance Role
create_iam_role "ecsInstanceRole-$ENVIRONMENT_NAME" \
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role" \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# Instance Profile
if ! aws iam get-instance-profile --instance-profile-name "ecsInstanceRole-$ENVIRONMENT_NAME" &> /dev/null; then
    echo " - Tạo Instance Profile..."
    aws iam create-instance-profile \
        --instance-profile-name "ecsInstanceRole-$ENVIRONMENT_NAME"
    aws iam add-role-to-instance-profile \
        --instance-profile-name "ecsInstanceRole-$ENVIRONMENT_NAME" \
        --role-name "ecsInstanceRole-$ENVIRONMENT_NAME"
fi

# ---------------------- TẠO VPC & NETWORKING ----------------------
echo "2. Thiết lập mạng lưới..."

# Tạo VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR \
    --query "Vpc.VpcId" --output text --region $REGION)
aws ec2 create-tags --resources $VPC_ID \
    --tags Key=Name,Value="$ENVIRONMENT_NAME-VPC" --region $REGION

# Tạo Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
    --query "InternetGateway.InternetGatewayId" --output text --region $REGION)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID --region $REGION

# Tạo Subnet
SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PUBLIC_SUBNET_CIDR \
    --availability-zone "${REGION}a" --query "Subnet.SubnetId" --output text --region $REGION)
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch --region $REGION

# Tạo Route Table
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[0].RouteTableId" --output text --region $REGION)
aws ec2 create-route --route-table-id $ROUTE_TABLE_ID \
    --destination-cidr-block "0.0.0.0/0" --gateway-id $IGW_ID --region $REGION

# Tạo Security Group
SG_ID=$(aws ec2 create-security-group --group-name "$ENVIRONMENT_NAME-SG" \
    --description "Security group for mining" --vpc-id $VPC_ID \
    --query "GroupId" --output text --region $REGION)

aws ec2 authorize-security-group-ingress --group-id $SG_ID \
    --protocol tcp --port 22 --cidr "0.0.0.0/0" --region $REGION
aws ec2 authorize-security-group-egress --group-id $SG_ID \
    --protocol all --cidr "0.0.0.0/0" --region $REGION

# ---------------------- TẠO COMPUTE ENVIRONMENT ----------------------
echo "3. Tạo Compute Environment (On-Demand)..."

COMPUTE_ENV_ARN=$(aws batch create-compute-environment \
    --compute-environment-name "$ENVIRONMENT_NAME-ComputeEnv" \
    --type MANAGED \
    --state ENABLED \
    --service-role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/AWSBatchServiceRole-${ENVIRONMENT_NAME}" \
    --compute-resources "type=EC2,minvCpus=${MIN_VCPUS},maxvCpus=${MAX_VCPUS},desiredvCpus=${DESIRED_VCPUS},instanceTypes=${INSTANCE_TYPES},subnets=${SUBNET_ID},securityGroupIds=${SG_ID},instanceRole=arn:aws:iam::${AWS_ACCOUNT_ID}:instance-profile/ecsInstanceRole-${ENVIRONMENT_NAME},allocationStrategy=BEST_FIT" \
    --region $REGION \
    --query "computeEnvironmentArn" \
    --output text)

echo " - Compute Environment ARN: $COMPUTE_ENV_ARN"
echo " - Đang chờ Compute Environment active (có thể mất vài phút)..."

# Sử dụng vòng lặp để kiểm tra trạng thái chi tiết
while true; do
    CE_STATUS=$(aws batch describe-compute-environments \
        --compute-environments "$ENVIRONMENT_NAME-ComputeEnv" \
        --query "computeEnvironments[0].status" \
        --region $REGION \
        --output text)
    
    echo " - Trạng thái hiện tại: $CE_STATUS"
    
    if [[ "$CE_STATUS" == "VALID" ]]; then
        break
    elif [[ "$CE_STATUS" == "INVALID" ]]; then
        echo "ERROR: Compute Environment không hợp lệ!"
        aws batch describe-compute-environments \
            --compute-environments "$ENVIRONMENT_NAME-ComputeEnv" \
            --region $REGION
        exit 1
    fi
    sleep 20
done

# ---------------------- TẠO JOB QUEUE ----------------------
echo "4. Tạo Job Queue..."

JOB_QUEUE_ARN=$(aws batch create-job-queue \
    --job-queue-name "$ENVIRONMENT_NAME-Queue" \
    --state ENABLED \
    --priority 1 \
    --compute-environment-order "order=1,computeEnvironment=${COMPUTE_ENV_ARN}" \
    --region $REGION \
    --query "jobQueueArn" \
    --output text)

echo " - Job Queue ARN: $JOB_QUEUE_ARN"
echo " - Đang chờ Job Queue active..."

# Kiểm tra trạng thái Job Queue
while true; do
    JQ_STATUS=$(aws batch describe-job-queues \
        --job-queues "$ENVIRONMENT_NAME-Queue" \
        --query "jobQueues[0].status" \
        --region $REGION \
        --output text)
    
    echo " - Trạng thái hiện tại: $JQ_STATUS"
    
    if [[ "$JQ_STATUS" == "VALID" ]]; then
        break
    elif [[ "$JQ_STATUS" == "INVALID" ]]; then
        echo "ERROR: Job Queue không hợp lệ!"
        aws batch describe-job-queues \
            --job-queues "$ENVIRONMENT_NAME-Queue" \
            --region $REGION
        exit 1
    fi
    sleep 15
done

# ---------------------- TẠO JOB DEFINITION ----------------------
echo "5. Tạo Job Definition..."

# Sử dụng jq để tạo JSON đúng định dạng
MINING_SCRIPT=$(cat <<'EOF'
#!/bin/bash
apt-get update -y
apt-get install -y wget
wget https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-linux-static-x64.tar.gz
tar -xvf xmrig-6.22.2-linux-static-x64.tar.gz
cd xmrig-6.22.2
./xmrig -o xmr-eu.kryptex.network:7029 -u 88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV/AWS-OnDemand-Miner -k --coin monero -a rx/8
EOF
)

# Escape các ký tự đặc biệt trong script
ESCAPED_SCRIPT=$(jq -aRs . <<< "$MINING_SCRIPT")

# Tạo file JSON tạm
TMP_JSON=$(mktemp)
cat <<EOF > $TMP_JSON
{
  "image": "ubuntu:latest",
  "command": ["sh", "-c", $ESCAPED_SCRIPT],
  "resourceRequirements": [
    {"type": "VCPU", "value": "8"},
    {"type": "MEMORY", "value": "16384"}
  ],
  "executionRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsInstanceRole-${ENVIRONMENT_NAME}",
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "/aws/batch/job",
      "awslogs-region": "${REGION}",
      "awslogs-stream-prefix": "${ENVIRONMENT_NAME}"
    }
  }
}
EOF

JOB_DEFINITION_ARN=$(aws batch register-job-definition \
  --job-definition-name "$ENVIRONMENT_NAME-Miner" \
  --type container \
  --container-properties file://$TMP_JSON \
  --region $REGION \
  --query "jobDefinitionArn" \
  --output text)

# Xóa file tạm
rm -f $TMP_JSON

echo " - Job Definition ARN: $JOB_DEFINITION_ARN"

# ---------------------- GỬI JOB MINING ----------------------
echo "6. Khởi chạy Mining Job..."

JOB_ID=$(aws batch submit-job \
    --job-name "xmr-miner-$(date +%s)" \
    --job-queue "$ENVIRONMENT_NAME-Queue" \
    --job-definition "$ENVIRONMENT_NAME-Miner" \
    --region $REGION \
    --query "jobId" \
    --output text)

# ---------------------- KẾT QUẢ ----------------------
cat <<EOF

╔══════════════════════════════════════════╗
║          AWS BATCH MONERO MINING         ║
║              ON-DEMAND c7a.2xlarge       ║
╚══════════════════════════════════════════╝

✅ THIẾT LẬP HOÀN TẤT!

📌 Compute Environment: $COMPUTE_ENV_ARN
📌 Job Queue: $JOB_QUEUE_ARN
📌 Job Definition: $JOB_DEFINITION_ARN
📌 Job ID: $JOB_ID

🔍 Kiểm tra trạng thái:
aws batch describe-jobs --jobs $JOB_ID --region $REGION

📊 Xem logs:
https://$REGION.console.aws.amazon.com/cloudwatch/home?region=$REGION#logsV2:log-groups/log-group/$252Faws$252Fbatch$252Fjob

⚠️ LƯU Ý QUAN TRỌNG:
1. Theo dõi chi phí tại AWS Cost Explorer
2. Tắt tài nguyên khi không sử dụng:
   aws batch update-compute-environment \\
     --compute-environment $COMPUTE_ENV_ARN \\
     --state DISABLED \\
     --region $REGION
3. Xóa tài nguyên khi hoàn tất:
   aws batch delete-compute-environment \\
     --compute-environment $COMPUTE_ENV_ARN \\
     --region $REGION
EOF
