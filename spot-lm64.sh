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

# ========= TẢI USER‑DATA =========
echo "📥 Downloading user‑data…"
curl -sL "$user_data_url" -o "$user_data_file"
[[ -s "$user_data_file" ]] || { echo "❌ Cannot download user‑data"; exit 1; }
user_data_b64=$(base64 -w0 "$user_data_file")

# ========= VÒNG LẶP QUA REGION =========
for region in "${!region_image_map[@]}"; do
  echo -e "\n🌎 Region: $region"
  image_id="${region_image_map[$region]}"
  key_name="KeyPair-$region"
  sg_name="SG-Vixmr-$region"
  lt_name="LT-Vixmr-$region"
  asg_name="ASG-Vixmr-$region"

  # ---- Key Pair ----
  if aws ec2 describe-key-pairs --region "$region" --key-names "$key_name" >/dev/null 2>&1; then
    echo "🔑 KeyPair $key_name exists"
  else
    aws ec2 create-key-pair --region "$region" \
      --key-name "$key_name" --query "KeyMaterial" --output text > "${key_name}.pem"
    chmod 400 "${key_name}.pem"
    echo "✅ Created KeyPair $key_name"
  fi

  # ---- Security Group ----
  sg_id=$(aws ec2 describe-security-groups --region "$region" \
          --group-names "$sg_name" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "")
  if [[ -z "$sg_id" ]]; then
    sg_id=$(aws ec2 create-security-group --region "$region" \
            --group-name "$sg_name" --description "Vixmr SG" \
            --query "GroupId" --output text)
    echo "✅ Created SG $sg_name ($sg_id)"
  else
    echo "🛡️  SG $sg_name exists ($sg_id)"
  fi

  # mở SSH nếu cần
  if ! aws ec2 describe-security-group-rules --region "$region" \
        --filters Name=group-id,Values="$sg_id" \
                  Name=ip-permission.from-port,Values=22 \
                  Name=ip-permission.to-port,Values=22 \
                  Name=ip-permission.cidr,Values=0.0.0.0/0 \
        --query "SecurityGroupRules" --output text | grep -q . ; then
    aws ec2 authorize-security-group-ingress --region "$region" \
      --group-id "$sg_id" --protocol tcp --port 22 --cidr 0.0.0.0/0
    echo "🔓 Opened SSH 22 on SG"
  fi

  # ---- Chọn subnet(s) ----
  subnet_ids=$(aws ec2 describe-subnets --region "$region" \
                --filters Name=default-for-az,Values=false \
                --query "Subnets[].SubnetId" --output text | tr '\t' ',')
  [[ -n "$subnet_ids" ]] || { echo "❌ No subnet in $region"; continue; }

  # ---- Launch Template (tạo hoặc cập nhật) ----
  lt_id=$(aws ec2 describe-launch-templates --region "$region" \
          --launch-template-names "$lt_name" \
          --query "LaunchTemplates[0].LaunchTemplateId" --output text 2>/dev/null || echo "")
  if [[ -z "$lt_id" ]]; then
    lt_id=$(aws ec2 create-launch-template --region "$region" \
      --launch-template-name "$lt_name" \
      --version-description "v1" \
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

  # ---- Auto Scaling Group (tạo hoặc cập nhật) ----
  if aws autoscaling describe-auto-scaling-groups --region "$region" \
         --auto-scaling-group-names "$asg_name" \
         --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null | grep -q "$asg_name"; then
    echo "🔄 Updating ASG $asg_name"
    aws autoscaling update-auto-scaling-group --region "$region" \
      --auto-scaling-group-name "$asg_name" \
      --launch-template "LaunchTemplateId=$lt_id,Version=1" \
      --min-size "$min_size" --desired-capacity "$desired_size" --max-size "$max_size"
  else
    echo "🛠️  Creating ASG $asg_name"
    aws autoscaling create-auto-scaling-group --region "$region" \
      --auto-scaling-group-name "$asg_name" \
      --launch-template "LaunchTemplateId=$lt_id,Version=1" \
      --min-size "$min_size" --desired-capacity "$desired_size" --max-size "$max_size" \
      --vpc-zone-identifier "$subnet_ids" \
      --mixed-instances-policy "{
         \"LaunchTemplate\":{
           \"LaunchTemplateSpecification\":{
             \"LaunchTemplateId\":\"$lt_id\",\"Version\":\"1\"
           }
         },
         \"InstancesDistribution\":{
           \"OnDemandPercentageAboveBaseCapacity\":0,
           \"SpotAllocationStrategy\":\"capacity-optimized\"
         }
       }"
  fi

  # Bật Capacity Rebalance
  aws autoscaling put-auto-scaling-group-capacity-rebalance --region "$region" \
      --auto-scaling-group-name "$asg_name" --enabled
  echo "✅ ASG $asg_name ready – will auto‑replace Spot instance when lost."

done

echo -e "\n🎉 Hoàn tất – mỗi region luôn duy trì 1 Spot Instance và tự động request lại khi bị thu hồi!"
