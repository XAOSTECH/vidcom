# VIDCOM - Video Compilation Pipeline
# Build system for C components

CC = gcc
CFLAGS = -Wall -Wextra -O2 -march=native -std=c17 -D_GNU_SOURCE
CFLAGS += -I/usr/local/include

# Use pkg-config for FFmpeg (handles static lib dependencies)
FFMPEG_CFLAGS := $(shell pkg-config --cflags libavformat libavcodec libavutil libswscale 2>/dev/null)
FFMPEG_LIBS := $(shell pkg-config --libs libavformat libavcodec libavutil libswscale 2>/dev/null || echo "-lavformat -lavcodec -lavutil -lswscale")

# ONNX Runtime
ONNX_LIBS = -lonnxruntime

CFLAGS += $(FFMPEG_CFLAGS)
LDFLAGS = -L/usr/local/lib -Wl,-rpath,/usr/local/lib
LDLIBS = $(ONNX_LIBS) $(FFMPEG_LIBS) -lswresample -lm -lpthread -lz -lbz2

# Optional CUDA support (comment out if not using GPU)
CUDA_HOME ?= /usr/local/cuda
CFLAGS += -I$(CUDA_HOME)/include
LDFLAGS += -L$(CUDA_HOME)/lib64
LDLIBS += -lcudart

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin

SRC_DIR = src
INC_DIR = include
BUILD_DIR = build
BIN = vidcom

# Source files
SRCS = $(wildcard $(SRC_DIR)/*.c)
OBJS = $(SRCS:$(SRC_DIR)/%.c=$(BUILD_DIR)/%.o)
DEPS = $(OBJS:.o=.d)

# Header files for dependency tracking
HDRS = $(wildcard $(INC_DIR)/*.h)

.PHONY: all clean install uninstall deps test help

all: $(BUILD_DIR)/$(BIN)

# Link final binary
$(BUILD_DIR)/$(BIN): $(OBJS)
	@mkdir -p $(BUILD_DIR)
	@echo "  LINK    $@"
	@$(CC) $(OBJS) -o $@ $(LDFLAGS) $(LDLIBS)

# Compile source files
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c $(HDRS)
	@mkdir -p $(BUILD_DIR)
	@echo "  CC      $<"
	@$(CC) $(CFLAGS) -I$(INC_DIR) -MMD -MP -c $< -o $@

# Include dependency files
-include $(DEPS)

# Install dependencies (TensorRT, ONNX Runtime, jq)
deps:
	@echo "Installing dependencies..."
	@chmod +x scripts/build-deps.sh
	@./scripts/build-deps.sh

# Install to system
install: $(BUILD_DIR)/$(BIN)
	@echo "Installing to $(PREFIX)..."
	install -d $(BINDIR)
	install -m 755 $(BUILD_DIR)/$(BIN) $(BINDIR)/
	install -m 755 scripts/yt-auth.sh $(BINDIR)/vidcom-auth
	install -m 755 scripts/yt-upload.sh $(BINDIR)/vidcom-upload
	install -m 755 scripts/encode-short.sh $(BINDIR)/vidcom-encode
	install -m 755 scripts/process-batch.sh $(BINDIR)/vidcom-batch

uninstall:
	rm -f $(BINDIR)/$(BIN)
	rm -f $(BINDIR)/vidcom-auth
	rm -f $(BINDIR)/vidcom-upload
	rm -f $(BINDIR)/vidcom-encode
	rm -f $(BINDIR)/vidcom-batch

# Run tests
test: $(BUILD_DIR)/$(BIN)
	@echo "Running tests..."
	@./tests/test_classifier.sh
	@./tests/test_upload.sh

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)

# Deep clean (including downloaded models)
distclean: clean
	rm -f models/*.onnx
	rm -f models/*.db

# Download pre-trained models
models:
	@mkdir -p models
	@echo "Downloading ResNet-50 ONNX model..."
	@if [ ! -f models/resnet50.onnx ]; then \
		wget -q --show-progress \
			-O models/resnet50.onnx \
			"https://github.com/onnx/models/raw/main/validated/vision/classification/resnet/model/resnet50-v1-7.onnx" || \
		wget -q --show-progress \
			-O models/resnet50.onnx \
			"https://huggingface.co/onnxmodelzoo/resnet/resolve/main/resnet50-v1-7.onnx"; \
	else \
		echo "Model already downloaded"; \
	fi

help:
	@echo "VIDCOM - Video Compilation Pipeline"
	@echo ""
	@echo "Targets:"
	@echo "  all        Build the vidcom binary (default)"
	@echo "  deps       Install system dependencies (TensorRT, ONNX Runtime)"
	@echo "  install    Install vidcom to $(PREFIX)/bin"
	@echo "  uninstall  Remove vidcom from system"
	@echo "  test       Run test suite"
	@echo "  models     Download pre-trained ONNX models"
	@echo "  clean      Remove build artifacts"
	@echo "  distclean  Remove build artifacts and downloaded models"
	@echo "  help       Show this help message"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX     Installation prefix (default: /usr/local)"
	@echo "  CUDA_HOME  CUDA toolkit path (default: /usr/local/cuda)"
	@echo ""
	@echo "Quick start:"
	@echo "  make deps      # Install dependencies"
	@echo "  make           # Build"
	@echo "  make install   # Install to system"
