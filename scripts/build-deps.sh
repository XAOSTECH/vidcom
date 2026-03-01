#!/bin/bash
# build-deps.sh - Install VIDCOM dependencies (TensorRT, ONNX Runtime, jq)
# Run this in existing container OR these get baked into Dockerfile on rebuild

set -euo pipefail

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
ONNX_VERSION="${ONNX_VERSION:-1.20.1}"
TENSORRT_VERSION="${TENSORRT_VERSION:-10.8.0}"

# Detect CUDA version
if command -v nvcc &>/dev/null; then
    CUDA_VERSION=$(nvcc --version | grep -oP 'release \K[0-9]+\.[0-9]+')
    log_info "Detected CUDA version: $CUDA_VERSION"
else
    log_error "CUDA not found. Install CUDA toolkit first."
    exit 1
fi

# Determine CUDA major version for package selection
CUDA_MAJOR=$(echo "$CUDA_VERSION" | cut -d. -f1)
log_info "CUDA major version: $CUDA_MAJOR"

#------------------------------------------------------------------------------
# jq - JSON processor (apt)
#------------------------------------------------------------------------------
install_jq() {
    log_info "Installing jq..."
    if command -v jq &>/dev/null; then
        log_info "jq already installed: $(jq --version)"
        return 0
    fi
    
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends jq
    log_info "jq installed: $(jq --version)"
}

#------------------------------------------------------------------------------
# bc - Calculator for shell scripts (apt)
#------------------------------------------------------------------------------
install_bc() {
    log_info "Installing bc..."
    if command -v bc &>/dev/null; then
        log_info "bc already installed"
        return 0
    fi
    
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends bc
    log_info "bc installed"
}

#------------------------------------------------------------------------------
# TensorRT - High-performance inference (apt from NVIDIA repos)
#------------------------------------------------------------------------------
install_tensorrt() {
    log_info "Installing TensorRT..."
    
    # Check if already installed
    if dpkg -l | grep -q libnvinfer; then
        log_info "TensorRT already installed"
        dpkg-query -W 'libnvinfer*' 2>/dev/null | head -3 || true
        return 0
    fi
    
    # TensorRT is available from cuda-keyring repos (already installed in container)
    sudo apt-get update
    
    # Install lean runtime (smaller footprint, sufficient for inference)
    # Full 'tensorrt' meta-package is ~2GB, lean is ~200MB
    sudo apt-get install -y --no-install-recommends \
        libnvinfer-lean10 \
        libnvinfer-vc-plugin10 \
        libnvinfer-headers-dev \
        || {
            log_warn "Lean packages not found, trying full TensorRT..."
            sudo apt-get install -y --no-install-recommends tensorrt
        }
    
    # Lock versions to prevent accidental upgrades
    sudo apt-mark hold libnvinfer10 libnvinfer-lean10 2>/dev/null || true
    
    log_info "TensorRT installed successfully"
    dpkg-query -W 'libnvinfer*' 2>/dev/null | head -5 || true
}

#------------------------------------------------------------------------------
# ONNX Runtime - ML inference engine (pre-built binary, no pip)
#------------------------------------------------------------------------------
install_onnxruntime() {
    log_info "Installing ONNX Runtime ${ONNX_VERSION} (C API)..."
    
    # Check if already installed
    if [[ -f /usr/local/lib/libonnxruntime.so ]]; then
        log_info "ONNX Runtime already installed at /usr/local/lib/libonnxruntime.so"
        return 0
    fi
    
    local TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    
    # Download GPU build (includes CUDA and TensorRT execution providers)
    local ARCHIVE="onnxruntime-linux-x64-gpu-${ONNX_VERSION}.tgz"
    local URL="https://github.com/microsoft/onnxruntime/releases/download/v${ONNX_VERSION}/${ARCHIVE}"
    
    log_info "Downloading from: $URL"
    wget -q --show-progress "$URL" -O "$ARCHIVE" || {
        log_error "Failed to download ONNX Runtime. Check version availability."
        log_info "Available versions: https://github.com/microsoft/onnxruntime/releases"
        rm -rf "$TMPDIR"
        exit 1
    }
    
    tar -xzf "$ARCHIVE"
    
    local EXTRACTED_DIR="onnxruntime-linux-x64-gpu-${ONNX_VERSION}"
    
    # Install headers
    log_info "Installing headers to /usr/local/include/onnxruntime/"
    sudo mkdir -p /usr/local/include/onnxruntime
    sudo cp -r "${EXTRACTED_DIR}"/include/* /usr/local/include/
    
    # Install libraries
    log_info "Installing libraries to /usr/local/lib/"
    sudo cp "${EXTRACTED_DIR}"/lib/libonnxruntime*.so* /usr/local/lib/
    
    # Update library cache
    sudo ldconfig
    
    # Create pkg-config file (ONNX Runtime doesn't ship one)
    log_info "Creating pkg-config file..."
    sudo mkdir -p /usr/local/lib/pkgconfig
    sudo tee /usr/local/lib/pkgconfig/onnxruntime.pc > /dev/null << EOF
prefix=/usr/local
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: ONNX Runtime
Description: ONNX Runtime - cross-platform ML inference engine
Version: ${ONNX_VERSION}
Libs: -L\${libdir} -lonnxruntime
Cflags: -I\${includedir}
EOF
    
    # Create CMake config file
    log_info "Creating CMake config..."
    sudo mkdir -p /usr/local/share/cmake/onnxruntime
    sudo tee /usr/local/share/cmake/onnxruntime/onnxruntimeConfig.cmake > /dev/null << 'EOF'
# ONNXRuntime CMake Config
# Usage: find_package(onnxruntime REQUIRED)
#        target_link_libraries(mytarget onnxruntime::onnxruntime)

set(ONNXRUNTIME_INCLUDE_DIR "/usr/local/include")
set(ONNXRUNTIME_LIBRARY "/usr/local/lib/libonnxruntime.so")

if(NOT TARGET onnxruntime::onnxruntime)
    add_library(onnxruntime::onnxruntime SHARED IMPORTED)
    set_target_properties(onnxruntime::onnxruntime PROPERTIES
        IMPORTED_LOCATION "${ONNXRUNTIME_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${ONNXRUNTIME_INCLUDE_DIR}"
    )
endif()

set(onnxruntime_FOUND TRUE)
EOF
    
    # Cleanup
    cd /
    rm -rf "$TMPDIR"
    
    log_info "ONNX Runtime ${ONNX_VERSION} installed successfully"
    log_info "  Headers: /usr/local/include/onnxruntime_c_api.h"
    log_info "  Library: /usr/local/lib/libonnxruntime.so"
}

#------------------------------------------------------------------------------
# Verify installation
#------------------------------------------------------------------------------
verify_installation() {
    log_info "Verifying installation..."
    
    local ERRORS=0
    
    # Check jq
    if command -v jq &>/dev/null; then
        log_info "✓ jq: $(jq --version)"
    else
        log_error "✗ jq not found"
        ((ERRORS++))
    fi
    
    # Check bc
    if command -v bc &>/dev/null; then
        log_info "✓ bc: installed"
    else
        log_error "✗ bc not found"
        ((ERRORS++))
    fi
    
    # Check ONNX Runtime
    if [[ -f /usr/local/lib/libonnxruntime.so ]]; then
        log_info "✓ ONNX Runtime: /usr/local/lib/libonnxruntime.so"
    else
        log_error "✗ ONNX Runtime not found"
        ((ERRORS++))
    fi
    
    # Check TensorRT
    if dpkg -l | grep -q libnvinfer; then
        local TRT_VER=$(dpkg-query -W -f='${Version}' libnvinfer-lean10 2>/dev/null || dpkg-query -W -f='${Version}' libnvinfer10 2>/dev/null || echo "unknown")
        log_info "✓ TensorRT: $TRT_VER"
    else
        log_warn "⚠ TensorRT not installed (optional for CUDA EP)"
    fi
    
    # Check FFmpeg NVENC
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q nvenc; then
        log_info "✓ FFmpeg NVENC: available"
    else
        log_warn "⚠ FFmpeg NVENC not available"
    fi
    
    if [[ $ERRORS -eq 0 ]]; then
        log_info "All dependencies installed successfully!"
        return 0
    else
        log_error "$ERRORS dependency/dependencies failed to install"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
    log_info "=========================================="
    log_info "VIDCOM Dependency Installation"
    log_info "=========================================="
    
    install_jq
    install_bc
    install_tensorrt
    install_onnxruntime
    
    echo ""
    verify_installation
    
    echo ""
    log_info "Done! You can now build VIDCOM with 'make'"
}

main "$@"
