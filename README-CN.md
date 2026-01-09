# Android Application Performance Testing Guide

> **测试目标**：测量某Android应用在使用期间的CPU和内存性能
> **测试平台**：macOS,linux + Android 设备

---

## 第一步：测试前的准备工作

### 1.1 确认你有以下物品

- ✅ **Android 设备**（手机、平板或其他Android设备）
- ✅ **USB 数据线**（能够连接电脑和 Android 设备）
- ✅ **待测试的应用**已安装在 Android 设备上

### 1.2 了解你要测试的应用

在开始之前，你需要知道：

1. **应用的包名**（Package Name）
   - 这是应用在 Android 系统中的唯一标识
   - 格式通常像：`com.company.appname`

2. **如何找到应用的包名？**

   **方法 1：询问开发人员**（最简单）
   - 直接问应用开发者要包名

   **方法 2：查看 Android 设备**（需要连接设备后使用）
   ```bash
   # 列出所有正在运行的应用
   adb shell pm list packages
   
   # 搜索特定应用（把 youtube 替换成你的应用名）
   adb shell pm list packages | grep youtube
   ```

### 1.3 确认测试场景

你需要明确：
- 测试什么功能？（例如：视频播放、地图导航）
- 测试多长时间？（建议 5-20 分钟）
- 需要什么操作？（例如：播放视频、滑动页面）

## 第二步：安装必备工具

### 2.1 确保已安装以下工具

测试脚本需要以下工具，请确保已安装：

| 工具 | 说明 | 安装方法 (macOS的场合) |
|------|------|----------------------|
| **adb** | Android 调试工具 | `brew install --cask android-platform-tools` |
| **bc** | 命令行计算器 | `brew install bc` |
| **awk** | 文本处理工具 | 系统自带 |

### 2.2 验证工具安装

在终端执行以下命令验证：

```bash
# 检查所有工具
adb --version && bc --version && echo "✅ 所有工具已安装"
```

**如果提示 `command not found`**，请根据上表安装对应工具。

## 第三步：连接Android 设备

在终端执行：
```bash
adb devices
```

**正确输出示例：**
```
List of devices attached
ABCD1234567890	device
```

**重要说明：**
- `ABCD1234567890`：这是设备的序列号（每台设备不同）
- `device`：表示设备已连接且授权成功

**如果看到 `unauthorized`：**
- 说明设备未授权
- 检查设备屏幕是否有弹窗提示，点击"允许"

**如果看到 `List of devices attached`（下方为空）：**
- 说明设备未连接
- 检查 USB 线是否插好
- 尝试重新插拔 USB 线
- 确认 USB 调试已开启

### 3.5 多设备连接注意事项

**如果连接了多台 Android 设备：**

```bash
adb devices
```

可能看到：
```
List of devices attached
ABCD1234	device
EFGH5678	device
```

**处理方法：**
1. 只连接一台设备进行测试（推荐）
2. 或在测试脚本中指定设备序列号（见第四步）

---

## 第四步：配置测试脚本

### 4.1 下载测试脚本

测试脚本文件名：`android_app_perfbench.sh`

### 4.2 必须修改的配置项

打开并编辑脚本, 找到以下配置，根据你的测试需求修改：

#### 应用包名（必须修改）

```bash
# Application package name (main process name)
PACKAGE_NAME="com.xxx.yyy"
```

**修改为你的应用包名：**
```bash
PACKAGE_NAME="Your-APP-PackageName"
```

#### 测试时长（根据需要修改）

```bash
# Test duration (minutes)
TEST_DURATION_MINUTES=5
```

**说明：**
- 默认 5 分钟
- 可以改成 10、15、20 等
- 建议首次测试用 5 分钟

#### 采样间隔（通常不需要修改）

```bash
# Sampling interval (seconds)
CPU_INTERVAL=10    # CPU 每 10 秒采集一次
MEM_INTERVAL=10    # 内存每 10 秒采集一次
```

**说明：**
- 间隔越短，数据越详细，但文件越大
- 默认 10 秒已经足够详细

#### 设备序列号（多设备时需要）

```bash
# ADB device serial number (optional)
ADB_SERIAL=""
```

**如果只连接一台设备：**
- 保持为空：`ADB_SERIAL=""`

**如果连接多台设备：**
1. 先执行 `adb devices` 查看所有设备
2. 复制你要测试的设备序列号
3. 填入配置：
   ```bash
   ADB_SERIAL="ABCD1234567890"
   ```

#### 单核算力（必须修改）

```bash
# Single core DMIPS (default value)
SINGLE_CORE_DMIPS=20000
```

**说明：**
- 默认值为 20000，请根据具体硬件信息进行替换。
- 硬件信息通常有两种提供方式：
  1. **总的算力 + CPU 核数**
     - 计算公式：`SINGLE_CORE_DMIPS = 总的算力 / CPU 核数`
  2. **CPU 核数 + 每个核的对应算力**
     - 计算公式：`SINGLE_CORE_DMIPS = 每个核的算力叠加（总的算力） / CPU 核数`
- 请务必在测试前确认硬件信息并替换默认值。

## 第五步：运行性能测试

### 5.1 测试前的准备

#### 给脚本添加执行权限

```bash
chmod +x android_app_perfbench.sh
```

### 5.2 启动测试

#### 在 Android 设备上准备好应用

**重要**：在运行脚本之前
- ✅ 确保应用**未运行**（脚本会自动检测并清理残留进程）
- ✅ 充电线已连接（避免中途断电）
- ✅ 设备屏幕保持常亮（在开发者选项中设置"保持唤醒"）

#### 运行测试脚本

在终端执行：
```bash
./android_app_perfbench.sh
```

**脚本启动后会：**
1. 检查工具是否安装
2. 检查设备连接
3. 检查应用是否运行

### 5.3 测试过程中的操作

#### 当你看到这个提示时：

```
[INFO] Application com.xxx.xxx is not running, please start the application
[WARN] Please manually open the app and begin operations (e.g., play video)
[WARN] Press Enter to continue...
```

**你需要做：**
1. 打开待测试的应用
2. 开始你的测试场景（例如：播放视频）
3. 回到电脑终端，按 **Enter** 键

#### 脚本会自动开始采集数据

你会看到类似这样的输出：
```
[INFO] Starting test, total duration: 300 seconds (5 minutes)
[WARN] Please ensure the app is playing video!
[INFO] Starting initial sampling...
[INFO] CPU sampling [0s]: 45.00% → 9000 DMIPS
[INFO] Memory sampling [0s]: PSS=120.50 MB, RSS=250.30 MB (pid-by-pid, 3 processes)
[INFO] CPU sampling [10s]: 48.00% → 9600 DMIPS
[INFO] Memory sampling [10s]: PSS=122.30 MB, RSS=252.10 MB (pid-by-pid, 3 processes)
...
```

### 5.4 测试期间注意事项

如果需要在测试结束前停止：

1. 在终端按 `Ctrl + C`
2. 脚本会自动生成已有数据的报告
3. 报告中会标注"用户中断"

### 5.6 测试完成

当测试结束时，你会看到：
```
[INFO] Test completed!
[INFO] Analyzing data and generating report...
[INFO] Report generated: ./test_20260108_123456/report.md

==========================================
        Test Result Summary
==========================================

📊 CPU Performance (Multi-Process Total)
  Average: 45.30% (9060 DMIPS)
  Peak:    68.50% (13700 DMIPS)
  Minimum: 22.10% (4420 DMIPS)

💾 Memory Performance (PSS - Real Usage)
  Average: 132.50 MB
  Maximum: 145.80 MB
  Minimum: 120.00 MB

💾 Memory Performance (RSS - Including Shared)
  Average: 250.30 MB
  Maximum: 280.50 MB
  Minimum: 220.00 MB

🔍 Memory Leak Detection
  None (stable memory, slope 0.000012 MB/sec, start-to-end growth 2.50%)

==========================================

[INFO] Test completed! Please check the report: ./test_20260108_123456/report.md

==========================================
   Test results saved to directory:
   📁 test_20260108_123456
   
   Test ID: 20260108_123456
   
   Files included:
   - CPU data: ./test_20260108_123456/cpu_log.csv
   - Memory data: ./test_20260108_123456/mem_log.csv
   - Test report: ./test_20260108_123456/report.md
==========================================
```

---

## 常见问题解决

### ❓ 问题 1：脚本提示 `Application is not running`

**原因：** 
1. 应用确实未运行
2. 或包名配置错误

**解决方法：**
```bash
# 1. 列出所有正在运行的应用
adb shell ps -A | grep -i "关键词"

# 例如，搜索 youtube 相关的应用
adb shell ps -A | grep -i youtube

# 2. 找到正确的包名（最后一列）
# 3. 修改脚本中的 PACKAGE_NAME
```

### ❓ 问题 2：CPU 使用率超过 100%

**这是正常的！**

**原因：**
- Android 设备通常有多个 CPU 核心（例如 8 核）
- 应用可以同时使用多个核心
- CPU% 是所有进程的总和

**示例：**
- 4 核设备：理论最大 400%
- 8 核设备：理论最大 800%

### ⚠️ 多进程应用说明

现代 Android 应用通常包含多个进程：

```
com.xxx.app              ← 主进程
com.xxx.app:render       ← 渲染进程
com.xxx.app:media        ← 媒体进程
com.xxx.app_zygote       ← 系统进程
```

**脚本会自动统计所有相关进程：**
- 匹配规则：`包名` 或 `包名:xxx` 或 `包名_xxx`
- CPU：累加所有进程的 CPU%
- 内存：逐个统计后累加

## 📚 附录：快速参考

### 快速命令索引

```bash
# 检查工具安装
adb --version && bc --version

# 检查设备连接
adb devices

# 列出所有应用包名
adb shell pm list packages

# 查找特定应用
adb shell pm list packages | grep youtube

# 检查应用是否运行
adb shell ps -A | grep "com.xxx.app"

# 强制停止应用
adb shell am force-stop com.xxx.app

# 重启 ADB 服务
adb kill-server
adb start-server

# 赋予脚本执行权限
chmod +x android_app_perfbench.sh

# 运行测试
./test_youtube_perf_en.sh

# 查看报告
cat test_20260108_123456/report.md

# 用 Excel 打开 CSV 数据
open -a "Microsoft Excel" test_20260108_123456/cpu_log.csv
```

**祝测试顺利！** 🚀
