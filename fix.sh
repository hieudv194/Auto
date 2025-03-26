#!/bin/bash

ROLE_NAME="AWSBatchInstanceRole-MoneroMiningBatch-OnDemand-Fixed"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="us-west-2"
IAM_USER=$(aws iam get-user --query 'User.UserName' --output text)

echo "🔍 Checking IAM Role: $ROLE_NAME"

# Step 1: Fix Trust Relationship
TRUST_POLICY=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.AssumeRolePolicyDocument' --output json)
if [[ $TRUST_POLICY != *"ecs-tasks.amazonaws.com"* ]] || [[ $TRUST_POLICY != *"ec2.amazonaws.com"* ]]; then
    echo "⚠️ Trust Relationship is incorrect. Fixing it..."
    cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "ecs-tasks.amazonaws.com",
          "ec2.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    aws iam update-assume-role-policy --role-name $ROLE_NAME --policy-document file://trust-policy.json
    echo "✅ Trust Relationship fixed."
else
    echo "✅ Trust Relationship is correct."
fi

# Step 2: Attach Required Policies
echo "🔍 Checking and attaching necessary IAM policies..."
POLICIES=(
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
    "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
)

for POLICY in "${POLICIES[@]}"; do
    ATTACHED=$(aws iam list-attached-role-policies --role-name $ROLE_NAME --query "AttachedPolicies[?PolicyArn=='$POLICY'].PolicyArn" --output text)
    if [[ -z "$ATTACHED" ]]; then
        echo "⚠️ Attaching missing policy: $POLICY"
        aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY
    else
        echo "✅ Policy already attached: $POLICY"
    fi
done

# Step 3: Check IAM User Permissions
echo "🔍 Checking IAM User permissions for PassRole..."
PASSROLE_POLICY="AWSBatchPassRolePolicy"

aws iam get-user-policy --user-name $IAM_USER --policy-name $PASSROLE_POLICY &>/dev/null
if [[ $? -ne 0 ]]; then
    echo "⚠️ IAM User does not have PassRole permissions. Fixing..."
    cat <<EOF > passrole-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:aws:iam::$AWS_ACCOUNT_ID:role/$ROLE_NAME"
        }
    ]
}
EOF
    aws iam put-user-policy --user-name $IAM_USER --policy-name $PASSROLE_POLICY --policy-document file://passrole-policy.json
    echo "✅ IAM User now has PassRole permissions."
else
    echo "✅ IAM User already has PassRole permissions."
fi

# Step 4: Retry AWS Batch Job
echo "🔄 Retrying AWS Batch Job..."
aws batch submit-job \
    --job-name monero-mining-job-$(date +%s) \
    --job-queue MoneroMiningBatch-Queue \
    --job-definition MoneroMiningBatch-MoneroMiner \
    --region $AWS_REGION

echo "🎉 All fixes applied. Job submitted!"
