#!/bin/bash

cd /home/gmand/myprojects/ecs_pilot || exit 1

docker compose -f docker-compose.tyk.yml up -d

echo "Tyk is up."
docker compose -f docker-compose.tyk.yml ps