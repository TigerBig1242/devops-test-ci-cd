#!/bin/bash

REGISTRY_NAME="local-registry"
REGISTRY_PORT="5000"

APP_IMAGE_NAME="ci-cd-test-3"
APP_CONTAINER_NAME="ci-cd-app-test"
APP_PORT="8080"
APP_IMAGE_TAG="${1:-v1.0.3}"
NETWORK_NAME="ci-network"

LOCAL_IMAGE="${APP_IMAGE_NAME}:${APP_IMAGE_TAG}"
REGISTRY_IMAGE="localhost:${REGISTRY_PORT}/${APP_IMAGE_NAME}:${APP_IMAGE_TAG}"

LOG_FILE="./pipeline-$(date +%Y%m%d-%H%M%S).log"

#Color status
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#Log Function

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"
}

header() {
    echo "" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    echo "  $1" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

test_docker() {
    header "Stage 0: Test Docker"
    if ! command -v docker &> /dev/null; then
        error "Docker is not running!"
        return 1
    fi

    if ! docker info > /dev/null 2>&1; then
        error "Docker is not running"
        return 1
    fi

    success "Docker is ready"
    return 0
}

test_registry() {
    header "Stage 1: Test Registry"
    log "Test registry"

    if curl -s http://localhost:${REGISTRY_PORT}/v2/ > /dev/null 2>&1; then
        success "Registry is responding"
        return 0
    else 
        error "Registry is not responding"
        return 1
    fi
}

test_build_docker_image() {
    header "Stage 2: Test Build Docker Image"
    log "Testing  if image was build"
    if docker image inspect ${LOCAL_IMAGE} &> /dev/null; then
        success "Image build completed: ${LOCAL_IMAGE}"
        return 0
    else 
        error "Image not found: ${LOCAL_IMAGE}"
        return 1
    fi
}

test_push_image() {
    header "Stage 3: Test push image"
    log "Testing image was pushed..."

    local tags=$(curl -s http://localhost:${REGISTRY_PORT}/v2/${IMAGE_NAME}/tags/list)
    if echo "$tags" | grep -q "${APP_IMAGE_TAG}"; then
        success "Image found in registry: ${LOCAL_IMAGE}"
        return 0
    else 
        error "Image not found in registry ${LOCAL_IMAGE}"
        return 1
    fi
}

test_pull_image() {
    header "Stage 4:Test pull image"
    log "Testing image was pull"
    if docker image inspect ${REGISTRY_IMAGE} &> /dev/null; then
        succuss "Image pull successfully: ${REGISTRY_IMAGE}"
    else 
        error "Image was pull failed: ${REGISTRY_IMAGE}"
        return 1
    fi
}

start_registry(){
    header "Start Local Registry"

    if docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
        success "Registry already running"
        return 0
    fi

    log "Registry not running, starting local registry..."
    if docker ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
        log "starting existing registry container ${REGISTRY_NAME}"
        docker start ${REGISTRY_NAME}
    fi
    log "waiting to registry start..."
    sleep 3
    if test_registry; then
        success "Registry is ready at localhost:${REGISTRY_PORT}"
        return 0
    else
        error "Registry failed to start"
        return 1
    fi
}

pre_build_check() {
    log "Running pre-build check..."

    if docker image inspect ${LOCAL_IMAGE} &> /dev/null; then
        warn "Image already exist: ${LOCAL_IMAGE}"
        return 2
    fi
}

build_docker_image() {
    header "CI Stage 1: Build Docker Image"
    log "Pre-build validation"
    pre_build_check
    local check_result=$?

    if [ $check_result -eq 1 ]; then
        error "Pre-build checks failed"
        return 1
    elif [ $check_result -eq 2 ]; then
        return 0
    fi

    log "Building image ${LOCAL_IMAGE}..."
    log "Build context: $(pwd)"
    if docker build -t ${LOCAL_IMAGE} . ; then
        success "Docker build completed: ${LOCAL_IMAGE}"
        return 0
    else
        error "Docker build failed"
        return 1
    fi

    log "Verifying build image exist"
    if ! test_build_docker_image; then 
        error "Image verification failed - image not found after build"
        return 1
    fi

    log "Build summary"
    local size=$(docker images ${LOCAL_IMAGE} --format "{{.Size}}")
    local image_id=$(docker images ${LOCAL_IMAGE} --format "{{.ID}}")
    local created=$(docker images ${LOCAL_IMAGE} --format "{{.CreatedAt}}")

    success "Build completed successfully"
    log "---------------------------------"
    log "Image:     ${LOCAL_IMAGE}"
    log "Image ID:  ${image_id}"
    log "Size:      ${size}"
    log "Created:   ${created}"
    log "---------------------------------"

    return 0
}

push_image() {
    header "CI Stage 2: Push Image"
    log "Tagging image for registry..."
    docker tag ${LOCAL_IMAGE} ${REGISTRY_IMAGE} || return 1

    local REGISTRY_URL=$(echo ${REGISTRY_IMAGE} | cut -d'/' -f1)
    local IMAGE_NAME=$(echo ${REGISTRY_IMAGE} | cut -d'/' -f2 | cut -d':' -f1)
    local IMAGE_TAG=$(echo ${REGISTRY_IMAGE} | cut -d':' -f2)

    if curl -sf http://${REGISTRY_URL}:${REGISTRY_PORT}/v2/${IMAGE_NAME}/menifest/${APP_IMAGE_TAG} > /dev/null 2>&1; then
        warn "Image already existing in registry: ${REGISTRY_IMAGE}"
        return 0
    fi

    log "Pushing to registry: ${REGISTRY_IMAGE}"
    if docker push ${REGISTRY_IMAGE}; then
        success "Image pushed successfully!"
    else
        error "Push image to registry failed"
        return 1
    fi

    test_push_image || return 1

    success "Image pushed to registry completed: ${REGISTRY_IMAGE}"
}

pull_docker_image() {
    header "CD Stage: Pull and Deploy image"
    log "Pulling image ${REGISTRY_IMAGE}"

    if docker pull ${REGISTRY_IMAGE}; then 
        success "Image pull successfully"
        test_pull_image
    else 
        error "Image pull failed"
        return 1
    fi

    # Check container is running
    EXIST_CONTAINER=$(docker ps -aq -f name=^${REGISTRY_NAME}$)
    if [ -n "$EXIST_CONTAINER" ]; then
        echo "Found existing container ${EXIST_CONTAINER}"

        if docker ps -aq -f name=^${APP_CONTAINER_NAME}$ | grep -q .; then
            echo "Stopping running container..."
            docker stop ${APP_CONTAINER_NAME}
            echo "Container already stopped"
        fi
        echo "Remove old container"
        docker rm -f ${APP_CONTAINER_NAME}
        sleep 3
        echo "Old container removed"
    else
        echo "No existing container found"
    fi
    
    if docker run -d --name ${APP_CONTAINER_NAME} -p ${APP_PORT}:5000 --restart unless-stopped ${REGISTRY_IMAGE}; then 
        success "Container started successfully"
    else 
        error "Failed to start container"
        return 1
    fi

    # Checking container status
    docker ps -f name=^${APP_CONTAINER_NAME}$

    # Show logs
    docker logs --tail 10 ${APP_CONTAINER_NAME}
}

test_docker
test_registry
start_registry
build_docker_image
push_image
pull_docker_image