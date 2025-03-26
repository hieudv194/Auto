#!/bin/bash
# Script AWS Batch On-Demand với c7a.2xlarge cho Monero Mining
# Version: 2.0 - On-Demand Only

# ---------------------- CẤU HÌNH ----------------------
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ENVIRONMENT_NAME="XMR-OnDemand-c7a"

# Cấu hình Instance (On-Demand)
INSTANCE_TYPES="c7a.2xlarge"  # AMD EPYC 7th Gen, 8 vCPU, 16GB RAM
MIN_VCPUS=0
MAX_VCPUS=32                  # Giới hạn để kiểm soát chi phí
DESIRED_VCPUS=4

# Cấu hình Mining (THAY ĐỔI THÔNG TIN CỦA BẠN)
WALLET_ADDRESS="88NaRPxg9d16NwXYpMvXrLir1rqw9kMMbK6UZQSix59SiQtQZYdM1R4G8tmdsNvF1ZXTRAZsvEtLmQsoxWhYHrGYLzj6csV"
WORKER_ID="AWS-OnDemand-Miner"
MINING_POOL="xmr-eu.kryptex.network:7029"

# ---------------------- TẠO IAM ROLES ----------------------
echo "1. Thiết lập IAM Roles..."

# AWS Batch Service Role
aws iam create-role --role-name "AWSBatchServiceRole-$ENVIRONMENT_NAME" \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "batch.amazonaws.com"},
            "Action": "sts:AssumeRole"
        }]
    }' > /dev/null 2>&1 || echo "Role AWSBatchServiceRole đã tồn tại, bỏ qua..."

aws iam attach-role-policy --role-name "AWSBatchServiceRole-$ENVIRONMENT_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole

# EC2 Instance Role
aws iam create-role --role-name "ecsInstanceRole-$ENVIRONMENT_NAME" \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "ec2.amazonaws.com"},
            "Action": "sts:AssumeRole"
        }]
    }' > /dev/null 2>&1 || echo "Role ecsInstanceRole đã tồn tại, bỏ qua..."

aws iam attach-role-policy --role-name "ecsInstanceRole-$ENVIRONMENT_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

# Tạo Instance Profile
aws iam create-instance-profile \
    --instance-profile-name "ecsInstanceRole-$ENVIRONMENT_NAME" > /dev/null 2>&1
aws iam add-role-to-instance-profile \
    --instance-profile-name "ecsInstanceRole-$ENVIRONMENT_NAME" \
    --role-name "ecsInstanceRole-$ENVIRONMENT_NAME"

# ---------------------- TẠO VPC & NETWORKING ----------------------
echo "2. Thiết lập mạng lưới..."

# Tạo VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block "10.0.0.0/16" \
    --query "Vpc.VpcId" --output text --region $REGION)
aws ec2 create-tags --resources $VPC_ID \
    --tags Key=Name,Value="$ENVIRONMENT_NAME-VPC" --region $REGION

# Tạo Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --query "InternetGateway.InternetGatewayId" --output text --region $REGION)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID --region $REGION

# Tạo Subnet
SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block "10.0.1.0/24" \
    --availability-zone "${REGION}a" --query "Subnet.SubnetId" --output text --region $REGION)
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch --region $REGION

# Tạo Route Table
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
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

# ---------------------- TẠO COMPUTE ENVIRONMENT (ON-DEMAND) ----------------------
echo "3. Tạo Compute Environment (On-Demand c7a.2xlarge)..."

COMPUTE_ENV_ARN=$(aws batch create-compute-environment \
    --compute-environment-name "$ENVIRONMENT_NAME-ComputeEnv" \
    --type MANAGED \
    --state ENABLED \
    --service-role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/AWSBatchServiceRole-${ENVIRONMENT_NAME}" \
    --compute-resources "type=EC2,minvCpus=${MIN_VCPUS},maxvCpus=${MAX_VCPUS},desiredvCpus=${DESIRED_VCPUS},instanceTypes=${INSTANCE_TYPES},subnets=${SUBNET_ID},securityGroupIds=${SG_ID},instanceRole=arn:aws:iam::${AWS_ACCOUNT_ID}:instance-profile/ecsInstanceRole-${ENVIRONMENT_NAME},allocationStrategy=BEST_FIT" \
    --region $REGION \
    --query "computeEnvironmentArn" \
    --output text)

echo " - Đang chờ Compute Environment khởi tạo..."
aws batch wait compute-environment-valid \
    --compute-environments "$ENVIRONMENT_NAME-ComputeEnv" \
    --region $REGION

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

echo " - Đang chờ Job Queue khởi tạo..."
aws batch wait job-queue-valid \
    --job-queues "$ENVIRONMENT_NAME-Queue" \
    --region $REGION

# ---------------------- TẠO JOB DEFINITION ----------------------
echo "5. Tạo Job Definition..."

MINING_SCRIPT=$(cat <<EOF
#!/bin/bash
apt-get update -y
apt-get install -y wget
wget https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-22-2/xmrig-6.22.2-linux-static-x64.tar.gz
tar -xvf xmrig-6.22.2-linux-static-x64.tar.gz
cd xmrig-6.22.2
./xmrig -o ${MINING_POOL} -u ${WALLET_ADDRESS}/${WORKER_ID} -k --coin monero -a rx/8
EOF
)

JOB_DEFINITION_ARN=$(aws batch register-job-definition \
    --job-definition-name "$ENVIRONMENT_NAME-Miner" \
    --type container \
    --container-properties "$(
        jq -n \
            --arg image "ubuntu:latest" \
            --arg executionRole "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsInstanceRole-${ENVIRONMENT_NAME}" \
            --arg cmd "$MINING_SCRIPT" \
            '{
                image: $image,
                command: ["sh", "-c", $cmd],
                resourceRequirements: [
                    {type: "VCPU", value: "8"},
                    {type: "MEMORY", value: "16384"}
                ],
                executionRoleArn: $executionRole,
                logConfiguration: {
                    logDriver: "awslogs",
                    options: {
                        "awslogs-group": "/aws/batch/job",
                        "awslogs-region": "'"$REGION"'",
                        "awslogs-stream-prefix": "'"$ENVIRONMENT_NAME"'"
                    }
                }
            }'
    )" \
    --region $REGION \
    --query "jobDefinitionArn" \
    --output text)

# ---------------------- GỬI JOB MINING ----------------------
echo "6. Khởi chạy Mining Job..."

JOB_ID=$(aws batch submit-job \
    --job-name "xmr-on-demand-$(date +%s)" \
    --job-queue "$ENVIRONMENT_NAME-Queue" \
    --job-definition "$ENVIRONMENT_NAME-Miner" \
    --region $REGION \
    --query "jobId" \
    --output text)

# ---------------------- KẾT QUẢ ----------------------
cat <<EOF

╔══════════════════════════════════════════╗
║          AWS BATCH MONERO MINING         ║
║               ON-DEMAND c7a.2xlarge      ║
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

⚠️ Lưu ý:
1. Theo dõi chi phí tại AWS Cost Explorer
2. Thay đổi WALLET_ADDRESS trong script
3. Tắt tài nguyên khi không sử dụng

EOF
