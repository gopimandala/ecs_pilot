docker build -t gopi/main-api:latest .

docker tag gopi/main-api:latest \
  224350923820.dkr.ecr.ap-south-1.amazonaws.com/gopi/main-api:latest

docker push \
  224350923820.dkr.ecr.ap-south-1.amazonaws.com/gopi/main-api:latest
