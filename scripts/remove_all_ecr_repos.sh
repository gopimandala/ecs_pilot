# 1. Force drop the repositories from ECR completely
aws ecr delete-repository --repository-name gopi/main-api --force --region ap-south-1
aws ecr delete-repository --repository-name gopi/uc1 --force --region ap-south-1
aws ecr delete-repository --repository-name gopi/uc2 --force --region ap-south-1
