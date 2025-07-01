#!/bin/bash
set -euo pipefail

# ========= CẤU HÌNH =========
declare -A region_image_map=(
  ["us-east-1"]="ami-0e2c8caa4b6378d8c"
  ["us-west-2"]="ami-05d38da78ce859165"
)

instance_type="c7a.16xlarge"
user_data_url="https://raw.githubusercontent.com/hieudv194/Auto/refs/heads/main/Vixmr-LM64"
user_data_file="/tmp/user_data.sh"

min_size=1
desired_size=1
max_size=1

# ========= TẢI USER-DATA =========
echo "📥 Downloading user‑data..."
curl -sL "$user_data_url" -o "$user_data_file"
[[ -s "$user_data_file" ]] || { echo "❌ Cannot download user‑data"; exit 1; }
user_data_b64=$(base64 -w0 "$user_data_file")

# ========= VÒNG LẶP THEO REGION =========
for region in "${!region_image_map[@]}"; do
  echo -e "\n🌎  REGION: $region"
  image_id="${region_image_map[$region]}"
  key_name="KeyPair-$region"
  sg_name="SG-Vixmr-$region"
  lt_name="LT-Vixmr-$region"
  asg_name="ASG-Vixmr-$region"

  # ---- ĐẢM BẢO VPC & SUBNET ----
  vpc_id=$(aws ec2 describe-vpcs --region "$region" --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "None")
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    echo "ℹ️  No VPC in $region — creating default VPC..."
    vpc_id=$(aws ec2 create-default-vpc --region "$region" --query "Vpc.VpcId" --output text)
  fi

  subnet_ids=$(aws ec2 describe-subnets --region "$region" \
                --filters Name=vpc-id,Values="$vpc_id" \
                --query "Subnets[].SubnetId" --output text | tr '\t' ',')
  [[ -n "$subnet_ids" ]] || { echo "❌ No subnet in VPC $vpc_id"; continue; }

  # ---- KEY PAIR ----
  if aws ec2 describe-key-pairs --region "$region" --key-names "$key_name" >/dev/null 2>&1; then
    echo "🔑 KeyPair $key_name exists"
  else
    aws ec2 create-key-pair --region "$region" --key-name "$key_name" \
      --query "KeyMaterial" --output text > "${key_name}.pem"
    chmod 400 "${key_name}.pem"
    echo "✅ Created KeyPair $key_name"
  fi

  # ---- SECURITY GROUP ----
  sg_id=$(aws ec2 describe-security-groups --region "$region" \
          --group-names "$sg_name" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "")
  if [[ -z "$sg_id" ]]; then
    sg_id=$(aws ec2 create-security-group --region "$region" \
            --group-name "$sg_name" --description "Vixmr SG" \
            --vpc-id "$vpc_id" --query "GroupId" --output text)
    echo "✅ Created SG $sg_name ($sg_id)"
  else
    echo "🛡️  SG $sg_name exists ($sg_id)"
  fi

  # ---- MỞ SSH NẾU CẦN ----
  ssh_rule=$(aws ec2 describe-security-groups --region "$region" \
      --group-ids "$sg_id" \
      --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\` && ToPort==\`22\` && IpRanges[?CidrIp=='0.0.0.0/0']]" \
      --output text)
  if [[ -z "$ssh_rule" ]]; then
    aws ec2 authorize-security-group-ingress --region "$region" \
      --group-id "$sg_id" --protocol tcp --port 22 --cidr 0.0.0.0/0
    echo "🔓 Opened SSH 22"
  fi

  # ---- LAUNCH TEMPLATE ----
  lt_id=$(aws ec2 describe-launch-templates --region "$region" \
          --launch-template-names "$lt_name" \
          --query "LaunchTemplates[0].LaunchTemplateId" --output text 2>/dev/null || echo "")
  if [[ -z "$lt_id" ]]; then
    lt_id=$(aws ec2 create-launch-template --region "$region" \
      --launch-template-name "$lt_name" --version-description "v1" \
      --launch-template-data "{
        \"ImageId\":\"$image_id\",
        \"InstanceType\":\"$instance_type\",
        \"KeyName\":\"$key_name\",
        \"SecurityGroupIds\":[\"$sg_id\"],
        \"UserData\":\"$user_data_b64\",
        \"NetworkInterfaces\":[{
          \"DeviceIndex\":0,
          \"AssociatePublicIpAddress\":true
        }]
      }" --query "LaunchTemplate.LaunchTemplateId" --output text)
    echo "🚀 Created Launch Template $lt_name ($lt_id)"
  else
    echo "ℹ️  Launch Template $lt_name exists ($lt_id)"
  fi

  # ---- CHUẨN BỊ JSON MixedInstancesPolicy ----
  mixed_policy_json=$(cat <<EOF
{
  "LaunchTemplate": {
    "LaunchTemplateSpecification": {
      "LaunchTemplateId": "$lt_id",
      "Version": "1"
    }
  },
  "InstancesDistribution": {
    "OnDemandPercentageAboveBaseCapacity": 0,
    "SpotAllocationStrategy": "capacity-optimized"
  }
}
EOF
)

  # ---- AUTO SCALING GROUP ----
  if aws autoscaling describe-auto-scaling-groups --region "$region" \
        --auto-scaling-group-names "$asg_name" \
        --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null | grep -q "$asg_name"; then
    echo "🔄 Updating ASG $asg_name"
    aws autoscaling update-auto-scaling-group --region "$region" \
      --auto-scaling-group-name "$asg_name" \
      --min-size "$min_size" --desired-capacity "$desired_size" --max-size "$max_size"
    aws autoscaling put-mixed-instances-policy --region "$region" \
      --auto-scaling-group-name "$asg_name" \
      --mixed-instances-policy "$mixed_policy_json"
  else
    echo "🛠️  Creating ASG $asg_name"
    aws autoscaling create-auto-scaling-group --region "$region" \
      --auto-scaling-group-name "$asg_name" \
      --min-size "$min_size" --desired-capacity "$desired_size" --max-size "$max_size" \
      --vpc-zone-identifier "$subnet_ids" \
      --mixed-instances-policy "$mixed_policy_json" \
      --tags "Key=Name,Value=Vixmr-Spot-$region"
  fi

  # ---- CAPACITY REBALANCE ----
  aws autoscaling put-auto-scaling-group-capacity-rebalance --region "$region" \
      --auto-scaling-group-name "$asg_name" --enabled

  echo "✅  ASG $asg_name ready – auto‑replaces Spot instance when lost."
done

echo -e "\n🎉  DONE – Mỗi vùng luôn duy trì 1 Spot Instance và tự động request lại khi bị thu hồi!"
