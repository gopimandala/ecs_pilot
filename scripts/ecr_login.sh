# 1. Log back into ECR (Make sure your AWS CLI credentials are active)
aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS --password-stdin 224350923820.dkr.ecr.ap-south-1.amazonaws.com
