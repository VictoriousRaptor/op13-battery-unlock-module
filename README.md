# 一加 13 电池解容模块

适用于一加 13 的 KernelSU 模块。WebUI 可调节关机截止电压，并切换真实电量显示及超级省电策略。

**卸载前请确认电量高于 30%、单芯电压高于 3.30 V，手动打开 WebUI 点击「恢复原厂」，等待校验成功后再回 KernelSU 卸载。**

本仓库基于枫落1911 的 [op13-battery-unlock v12](https://github.com/aapplle/op13-battery-unlock/tree/00bc6747285a0e662c4e3947e7770966a545ad2e)，采用 [GPL-2.0](LICENSE)。本版本加入卸载确认、单键策略恢复和恢复成功后的清理。随附的内核模块沿用上游 v12 预编译文件。

## 打包与验证

在仓库根目录运行以下命令，可从当前提交生成 KernelSU 安装包并执行宿主侧 WebUI 冒烟测试。

```sh
git -c core.autocrlf=false archive --format=zip --output=op13-battery-unlock.zip HEAD:模块源目录
sh 自动化测试矩阵/dev/webui_host_smoke.sh
```

# 一、Linux 内核源码树 —— GPL-2.0

## 1.1 上游仓库（固定版本）

| 用途 | 仓库 | 分支 | 固定 commit |
|---|---|---|---|
| **编译模块（必需）** | [OnePlusOSS/android_kernel_oneplus_sm8750](https://github.com/OnePlusOSS/android_kernel_oneplus_sm8750) | `oneplus/sm8750_b_16.0.0_oneplus_13` | `6028f47faddaa27700f8dd3a1d83906ea8f27170` |
| 厂商驱动 + 设备树（阅读/对照用，**非编译必需**） | [OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750) | `oneplus/sm8750_b_16.0.0_oneplus_13` | `d50b305f7da9e14715a25120a4ac7b1a4b8b97c3` |

- **内核版本**：Linux 6.6.118
- **许可证**：GPL-2.0（树内 `COPYING`：`SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note`）
- **版权**：归 OnePlus / OPPO 及 Linux 内核贡献者所有；本仓库仅为构建时引用，不主张其版权

## 1.3 拉取

```sh
./fetch-kernel.sh
# 默认落到 ./编译用内核树/android_kernel_oneplus_sm8750
```

## 1.4 编译

```sh
export PATH=/usr/lib/llvm-18/bin:$PATH
ROOT="$PWD"
KT="$ROOT/编译用内核树/android_kernel_oneplus_sm8750"
KB="$ROOT/编译前置"

# 1) 用编译前置里的 device_config 配置内核树（首次需要）
cp "$KB/device_config" "$KT/.config"
cd "$KT"
make ARCH=arm64 LLVM=1 olddefconfig
make ARCH=arm64 LLVM=1 modules_prepare
cp "$KB/Module.symvers" "$KT/Module.symvers"

# 2) 编译模块（源码在 内核源码/）
make ARCH=arm64 LLVM=1 M="$ROOT/内核源码" modules
llvm-strip --strip-debug "$ROOT/内核源码/uv2800.ko"

# 3) 打包发布 zip（从 模块源目录/ 构建）
cd "$ROOT/模块源目录" && zip -q -r "$ROOT/一加13解容-v$(grep '^version=' module.prop | cut -d= -f2).zip" .
```

> 也可以直接用 `自动化测试矩阵/build.sh`（它封装了 2)+3) 两步）。

**产物核验基线**：`.gnu.linkonce.this_module` 节区大小应严格为 `0x600`（1536 字节）。

