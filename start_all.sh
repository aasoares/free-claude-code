#!/bin/bash
# ==============================================================================
# NVIDIA Proxy Stack - Startup Script (Linux/macOS)
# ==============================================================================
# Starts the full stack: NIM + NVIDIA Proxy + Hybrid Proxy + Prometheus + Grafana
#
# Prerequisites:
#   - Docker & Docker Compose installed
#   - NVIDIA Container Toolkit (for GPU support)
#   - NGC_API_KEY set in .env or environment
#
# Usage:
#   ./start_all.sh              # Start all services
#   ./start_all.sh --build      # Rebuild images before starting
#   ./start_all.sh --logs       # Follow logs after starting
#   ./start_all.sh --stop       # Stop all services
#   ./start_all.sh --clean      # Stop and remove volumes
# ==============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"

# Default options
BUILD=false
FOLLOW_LOGS=false
STOP=false
CLEAN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --build)
            BUILD=true
            shift
            ;;
        --logs)
            FOLLOW_LOGS=true
            shift
            ;;
        --stop)
            STOP=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--build] [--logs] [--stop] [--clean]"
            echo "  --build    Rebuild Docker images before starting"
            echo "  --logs     Follow logs after starting"
            echo "  --stop     Stop all services"
            echo "  --clean    Stop and remove volumes (data loss!)"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Helper functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker not found. Please install Docker first."
        exit 1
    fi

    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Compose not found. Please install Docker Compose first."
        exit 1
    fi

    # Determine compose command
    if docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
    else
        COMPOSE_CMD="docker-compose"
    fi

    # Check NVIDIA Container Toolkit (for GPU)
    if ! docker info | grep -q "Runtimes:.*nvidia"; then
        log_warn "NVIDIA Container Toolkit not detected. GPU support may not work."
        log_warn "Install from: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
    fi

    # Check .env file
    if [[ ! -f "$ENV_FILE" ]]; then
        log_warn ".env file not found. Creating template..."
        cat > "$ENV_FILE" << 'EOF'
# NVIDIA Proxy Stack Environment Variables
# ========================================
# Get your NGC API key from: https://ngc.nvidia.com/setup/api-key
NGC_API_KEY=your-ngc-api-key-here

# Admin UI authentication token (optional)
ADMIN_TOKEN=your-secure-admin-token

# Grafana admin password
GRAFANA_PASSWORD=admin
EOF
        log_warn "Please edit .env and add your NGC_API_KEY before starting!"
        exit 1
    fi

    # Source .env to check NGC_API_KEY
    set -a
    source "$ENV_FILE"
    set +a

    if [[ -z "$NGC_API_KEY" || "$NGC_API_KEY" == "your-ngc-api-key-here" ]]; then
        log_error "NGC_API_KEY not set in .env file!"
        log_error "Get your API key from: https://ngc.nvidia.com/setup/api-key"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

stop_services() {
    log_info "Stopping services..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" down
    log_success "Services stopped"
}

clean_services() {
    log_warn "This will remove all data volumes! Press Ctrl+C to cancel..."
    sleep 3
    log_info "Stopping and removing services with volumes..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" down -v --remove-orphans
    log_success "Services stopped and volumes removed"
}

start_services() {
    log_info "Starting NVIDIA Proxy Stack..."

    local build_flag=""
    if [[ "$BUILD" == true ]]; then
        build_flag="--build"
        log_info "Building images..."
    fi

    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d $build_flag

    log_success "Services started!"

    # Wait for health checks
    log_info "Waiting for services to be healthy..."
    sleep 5

    # Check service status
    $COMPOSE_CMD -f "$COMPOSE_FILE" ps

    echo ""
    log_success "=== Service Endpoints ==="
    echo -e "  ${GREEN}NVIDIA Proxy:${NC}      http://localhost:8089"
    echo -e "  ${GREEN}Admin Dashboard:${NC}   http://localhost:8089/admin/dashboard"
    echo -e "  ${GREEN}Metrics:${NC}            http://localhost:8089/metrics"
    echo -e "  ${GREEN}Hybrid Proxy:${NC}       http://localhost:3456"
    echo -e "  ${GREEN}Prometheus:${NC}         http://localhost:9091"
    echo -e "  ${GREEN}Grafana:${NC}            http://localhost:3000 (admin/admin)"
    echo ""
    echo -e "  ${GREEN}Health Checks:${NC}"
    echo -e "    NVIDIA Proxy:  curl http://localhost:8089/health"
    echo -e "    Hybrid Proxy:  curl http://localhost:3456/health"
    echo -e "    NIM:           curl http://localhost:8000/v1/models"
    echo ""
}

follow_logs() {
    log_info "Following logs (Ctrl+C to exit)..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" logs -f --tail=100
}

# Main execution
main() {
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         NVIDIA Proxy Stack - Startup Script                  ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_prerequisites

    if [[ "$STOP" == true ]]; then
        stop_services
        exit 0
    fi

    if [[ "$CLEAN" == true ]]; then
        clean_services
        exit 0
    fi

    start_services

    if [[ "$FOLLOW_LOGS" == true ]]; then
        follow_logs
    fi
}

main "$@"