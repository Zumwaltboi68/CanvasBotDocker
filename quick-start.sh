#!/bin/bash

# Canvas Quiz Bot - Quick Start Script
# This script builds and runs the Docker container

set -e

echo "========================================"
echo "Canvas Quiz Bot - Quick Start"
echo "========================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    echo "Please install Docker from https://docs.docker.com/get-docker/"
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker is not running${NC}"
    echo "Please start Docker and try again"
    exit 1
fi

echo -e "${GREEN}✓ Docker is installed and running${NC}"
echo ""

# Clean up old containers
if docker ps -a | grep -q canvas-quiz-bot; then
    echo -e "${YELLOW}Removing old container...${NC}"
    docker stop canvas-quiz-bot 2>/dev/null || true
    docker rm canvas-quiz-bot 2>/dev/null || true
fi

# Build the image
echo -e "${YELLOW}Building Docker image...${NC}"
echo "This may take 3-5 minutes on first build"
echo ""

docker build -t canvas-quiz-bot . || {
    echo -e "${RED}Build failed!${NC}"
    exit 1
}

echo ""
echo -e "${GREEN}✓ Image built successfully${NC}"
echo ""

# Run the container
echo -e "${YELLOW}Starting container...${NC}"
docker run -d \
    --name canvas-quiz-bot \
    --memory="2g" \
    --cpus="1.5" \
    --shm-size=2g \
    -p 3000:3000 \
    -p 6080:6080 \
    canvas-quiz-bot

# Wait for container to be healthy
echo ""
echo -e "${YELLOW}Waiting for services to start...${NC}"
sleep 10

# Check health
for i in {1..30}; do
    if curl -s http://localhost:3000/api/health > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Container is healthy!${NC}"
        break
    fi
    
    if [ $i -eq 30 ]; then
        echo -e "${RED}Container failed to start properly${NC}"
        echo "Check logs with: docker logs canvas-quiz-bot"
        exit 1
    fi
    
    sleep 2
    echo -n "."
done

echo ""
echo ""
echo "========================================"
echo -e "${GREEN}Canvas Quiz Bot is Running!${NC}"
echo "========================================"
echo ""
echo -e "Web Interface:  ${GREEN}http://localhost:3000${NC}"
echo -e "noVNC Viewer:   ${GREEN}http://localhost:6080/vnc.html${NC}"
echo -e "Health Check:   ${GREEN}http://localhost:3000/api/health${NC}"
echo ""
echo "Useful commands:"
echo "  View logs:      docker logs -f canvas-quiz-bot"
echo "  Stop:           docker stop canvas-quiz-bot"
echo "  Start:          docker start canvas-quiz-bot"
echo "  Restart:        docker restart canvas-quiz-bot"
echo "  Remove:         docker stop canvas-quiz-bot && docker rm canvas-quiz-bot"
echo ""
echo "========================================"
