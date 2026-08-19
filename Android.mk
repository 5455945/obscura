# ==============================================================================
# Android.mk - obscura 集成至 AOSP 编译系统
#
# 两种编译模式：
#   1. 独立模式（OBSCURA_STANDALONE=1）：使用 AOSP 自带 clang/rust/sysroot
#   2. 非独立模式（默认）：使用 _deps/android/ 自有 NDK/Rust 工具链
#
# 使用方式：
#   1. 源码放到 vendor/banma/frameworks/libs/webengine/obscura/
#   2. 首次使用前: ./build_download_android.sh
#   3. OBSCURA_STANDALONE=1 m obscura -j24
#
# 可选变量（命令行覆盖）：
#   OBSCURA_BUILD_MODE=release|debug   编译模式（默认 debug；TARGET_BUILD_VARIANT=user 时为 release）
#   OBSCURA_JOBS=<N>                  cargo 并行度（默认 20，如 OBSCURA_JOBS=24）
#   OBSCURA_FEATURES="--features render"  额外 cargo feature（如 render / render,stealth / --no-default-features）
#
# 示例：
#   OBSCURA_STANDALONE=1 OBSCURA_BUILD_MODE=release OBSCURA_JOBS=24 m obscura -j24
#   OBSCURA_FEATURES="--features render" m obscura -j24
# ==============================================================================
LOCAL_PATH := $(call my-dir)

# ---- 编译模式 ----
# OBSCURA_BUILD_MODE 可被命令行覆盖：make ... OBSCURA_BUILD_MODE=release
ifndef OBSCURA_BUILD_MODE
ifeq ($(TARGET_BUILD_VARIANT),user)
    OBSCURA_BUILD_MODE := release
else
    OBSCURA_BUILD_MODE := debug
endif
endif
OBSCURA_PROFILE := $(OBSCURA_BUILD_MODE)

# ---- cargo 并行度 ----
# OBSCURA_JOBS 可被命令行覆盖：make ... OBSCURA_JOBS=24
ifndef OBSCURA_JOBS
    OBSCURA_JOBS := 20
endif

# ---- 额外 cargo 参数（透传给 build_android.sh → cargo） ----
# 用于传 --features render / --features render,stealth / --no-default-features 等
# 命令行覆盖：OBSCURA_FEATURES="--features render" m obscura -j24
ifndef OBSCURA_FEATURES
    OBSCURA_FEATURES := --features render
endif

# ---- 路径 ----
OBSCURA_BUILD_OUT  := $(LOCAL_PATH)/target/android-aarch64/aarch64-linux-android/$(OBSCURA_PROFILE)
OBSCURA_INSTALL    := $(TARGET_OUT_EXECUTABLES)
OBSCURA_STAMP_FILE := $(PRODUCT_OUT)/obj/EXECUTABLES/obscura_build_stamp

# ---- 编译命令 ----
ifneq ($(OBSCURA_STANDALONE),1)
    OBSCURA_BUILD_CMD := bash build_android.sh \
        --$(OBSCURA_BUILD_MODE) \
        --cargo-args "-j$(OBSCURA_JOBS)" \
	$(OBSCURA_FEATURES)
else
    OBSCURA_BUILD_CMD := bash build_android.sh \
        --$(OBSCURA_BUILD_MODE) \
        --cargo-args "-j$(OBSCURA_JOBS)" \
	$(OBSCURA_FEATURES)
endif

# AOSP clang 的 llvm-strip
AOSP_CLANG_DIR := $(abspath $(LOCAL_PATH)/../../../../../..)/prebuilts/clang/host/linux-x86/clang-r574158
OBSCURA_STRIP := $(AOSP_CLANG_DIR)/bin/llvm-strip

# ---- 编译 + 安装（一条规则，避免 BUILD_PREBUILT 路径问题）- ----
include $(CLEAR_VARS)
LOCAL_MODULE := obscura
LOCAL_MODULE_TAGS := optional
LOCAL_REQUIRED_MODULES := obscura-worker

$(OBSCURA_STAMP_FILE): PRIVATE_CMD     := $(OBSCURA_BUILD_CMD)
$(OBSCURA_STAMP_FILE): PRIVATE_PATH    := $(LOCAL_PATH)
$(OBSCURA_STAMP_FILE): PRIVATE_BUILD   := $(OBSCURA_BUILD_OUT)
$(OBSCURA_STAMP_FILE): PRIVATE_INSTALL := $(OBSCURA_INSTALL)
$(OBSCURA_STAMP_FILE): PRIVATE_STRIP   := $(OBSCURA_STRIP)
$(OBSCURA_STAMP_FILE): PRIVATE_MODE    := $(OBSCURA_BUILD_MODE)
$(OBSCURA_STAMP_FILE): $(LOCAL_PATH)/build_android.sh $(LOCAL_PATH)/_scripts/build_aosp.sh
	@echo "=== obscura build begin ($(OBSCURA_BUILD_MODE)) ==="
	@cd $(PRIVATE_PATH) && $(PRIVATE_CMD)
	@echo "=== obscura build done, installing ==="
	@mkdir -p $(PRIVATE_INSTALL)
	@cp $(PRIVATE_BUILD)/obscura $(PRIVATE_INSTALL)/obscura
	@cp $(PRIVATE_BUILD)/obscura-worker $(PRIVATE_INSTALL)/obscura-worker
ifeq ($(OBSCURA_BUILD_MODE),release)
	@echo "=== stripping ==="
	@$(OBSCURA_STRIP) $(PRIVATE_INSTALL)/obscura $(PRIVATE_INSTALL)/obscura-worker
endif
	@touch $@

LOCAL_ADDITIONAL_DEPENDENCIES := $(OBSCURA_STAMP_FILE)
include $(BUILD_PHONY_PACKAGE)

# obscura-worker：复用同一编译产物，仅作为独立 target 注册
include $(CLEAR_VARS)
LOCAL_MODULE := obscura-worker
LOCAL_MODULE_TAGS := optional
LOCAL_ADDITIONAL_DEPENDENCIES := $(OBSCURA_STAMP_FILE)
include $(BUILD_PHONY_PACKAGE)
