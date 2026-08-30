# Disk Scan - 磁盘容量扫描工具

[English](README_EN.md) | 中文

一个基于 PowerShell 的多线程磁盘容量扫描工具，通过 SMB 管理共享批量查询远程设备的磁盘使用情况，**自动发现所有磁盘分区**，生成带严重程度排序的 CSV 报告。

> **快速上手？** 下载后直接看 [USAGE.txt](USAGE.txt)（3 步运行，中英双语）。

## 特性

- **多线程扫描**：基于 RunspacePool，支持任意并发线程数；`ThreadDelay` 可控制发射节拍
- **多凭据尝试**：支持配置多组账户/密码，自动逐个尝试直到连接成功
- **配置外置**：线程数、超时、阈值等通过 `config.txt` 配置，无需修改脚本
- **动态磁盘发现**：自动枚举远程设备所有磁盘分区（C/D/E/F...），不限于固定盘符
- **统一分级**：所有磁盘使用同一套等级体系（OK/WARN/HIGH/CRITICAL）
- **纯 Win32 API**：使用 `GetDiskFreeSpaceEx` 查询磁盘空间，不依赖 COM，线程安全
- **实时进度**：完成一台输出一台，不用等全部跑完
- **严重程度排序**：CSV 报告按告警严重程度排序，最严重的在最上面
- **英文表头**：CSV 使用英文表头，通用且适配各种工具
- **离线设备关注**：离线设备单独列入 Need Attention 区域
- **Excel 友好**：CSV 使用 UTF-8 BOM 编码，Excel 打开不乱码
- **报告目录**：自动创建 `report/` 目录，CSV 保存在其中
- **便携部署**：解压即用，不依赖任何外部模块
- **非交互模式**：自动检测运行环境，管道/CI 场景不会卡在等待输入

## 快速开始

### 1. 配置凭据

**唯一方式：编辑 `credentials.txt`**

`scan.ps1` 不再包含任何内置凭据，也不支持 `credentials.ps1`。所有账号密码必须且只能在 `credentials.txt` 中配置。

项目已自带 `credentials.txt`（占位符），用记事本打开并填入真实密码即可。一行一组凭据：

```
# 用户名,密码（逗号分隔）
administrator,your_password_1
administrator,your_password_2
admin,backup@2025

# 无密码设备：
administrator,

# 密码带空格可用引号：
administrator," my password "
```

`#` 开头为注释，自动忽略。支持的分隔符：`,` `:` `|` 或 tab。**安全提示：编辑后请勿将真实密码提交到 GitHub。**

### 2. 编辑 IP 列表

编辑 `ip-list.txt`，一行一个 IP，`#` 开头为注释（自动忽略）：

```
# 生产网段
192.168.1.10
192.168.1.11

# 测试机
172.16.0.100
```

### 3. 运行

```powershell
# 如果提示"禁止运行脚本"，先执行一次（仅需一次）：
# Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 方式一：右键 scan.ps1 → "用 PowerShell 运行"
# 方式二：命令行
.\scan.ps1
```

### 4. 查看报告

扫描完成后，自动生成 `report/` 目录，报告保存在 `report/disk-report-yyMMdd_HHmmss.csv`（精确到秒；若同一秒内再次运行，自动追加 `-N` 序号）。

## 配置说明

所有运行参数均可通过 `config.txt` 配置；`credentials.txt` 仅保存账户/密码。

| 配置项 | 文件 | 说明 | 默认值 |
|--------|------|------|--------|
| `MaxThreads` | `config.txt` | 并发线程数（1=串行，大于1=多线程） | 2 |
| `PingTimeout` | `config.txt` | Ping 超时（毫秒） | 1000 |
| `SeqDelay` | `config.txt` | 串行模式设备间隔（毫秒） | 500 |
| `ThreadDelay` | `config.txt` | 并行模式每个 IP 的发射间隔（毫秒） | 50 |
| `Thresholds` | `config.txt` | 磁盘分级阈值 Warn/High/Critical | 50/70/85 |
| `Credentials` | `credentials.txt` | 账户/密码列表，支持多组 | 占位符 |

**关于 `MaxThreads` 的提示：** 线程数没有硬上限，但数值越大，同时发起的 SMB/网络连接越多。生产环境建议 `2-4`，内网稳定可 `10-20`，超过 `50` 可能冲击网络。配合 `ThreadDelay` 使用可在提高并行度的同时降低瞬间风暴。

## 状态说明

| 状态 | 含义 |
|------|------|
| `ONLINE` | 设备在线，已获取磁盘信息 |
| `OFFLINE` | Ping 不通（设备关机或网络不通） |
| `AUTH_FAIL` | Ping 通但所有凭据都连不上 |

## 磁盘分级

所有磁盘使用统一的分级体系：

| 等级 | 条件 | 含义 |
|------|------|------|
| `[OK]` | 使用率 < 50% | 健康 |
| `[WARN]` | 50% - 70% | 需关注 |
| `[HIGH]` | 70% - 85% | 高占用 |
| `[CRITICAL]` | >= 85% | 严重 |

阈值可在 `config.txt` 的 `Thresholds`、`ThresholdWarn`、`ThresholdHigh`、`ThresholdCritical` 中自定义。

## CSV 报告

**表头：**

```
IP, Status, Drive, Total_GB, Used_GB, Free_GB, Used_Pct, Level
```

**说明：** 每个磁盘一行，一个 IP 有多个分区时会有多行。离线/认证失败的设备只有一行（Drive 为 `-`）。

**排序（严重程度从高到低）：**

1. OFFLINE 离线设备
2. AUTH_FAIL 认证失败
3. 任意磁盘 [CRITICAL]（>= 85%）
4. 任意磁盘 [HIGH]（70% - 85%）
5. 任意磁盘 [WARN]（50% - 70%）
6. 磁盘 [OK]（< 50%）

同级内按使用率从高到低排。

## 环境要求

- **执行机**：Windows + PowerShell 5.1 或更高（PowerShell 7 同样兼容）
- **目标设备**：Windows，已开启 SMB 管理共享（`C$`、`D$` 等）
- **网络**：执行机到目标设备 SMB 端口 445 可达
- **凭据**：目标设备的管理员账户

### 常见问题

**"无法加载脚本，因为在此系统上禁止运行脚本"**

Windows 默认禁止运行 PowerShell 脚本。执行一次以下命令即可（仅需一次）：

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**目标设备没有管理共享（C$ 等）**

部分系统默认关闭管理共享。可在目标设备上通过注册表开启：

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System
LocalAccountTokenFilterPolicy = 1 (DWORD)
```

**防火墙阻止访问**

确保目标设备防火墙允许 SMB（端口 445）入站。域环境通常已默认放行。

## 技术实现

| 组件 | 方案 |
|------|------|
| 多线程 | RunspacePool（兼容 PowerShell 5.1） |
| 磁盘发现 | `net view \\IP` 解析管理共享，自动枚举所有盘符 |
| 网络连接 | `net use`（所有输出捕获避免污染 pipeline） |
| 磁盘查询 | Win32 API `GetDiskFreeSpaceEx`（P/Invoke，无 COM 依赖） |
| Ping | `System.Net.NetworkInformation.Ping`（.NET，可设超时） |
| 凭据管理 | 仅支持 `credentials.txt`（纯文本），`scan.ps1` 不再内置凭据 |

## 文件说明

| 文件 | 用途 |
|------|------|
| `scan.ps1` | 主脚本 |
| `ip-list.txt` | IP 列表（支持 `#` 注释） |
| `credentials.txt` | 凭据文件（纯文本，自带占位符，唯一入口，编辑后勿提交） |
| `report/` | 自动创建，存放 CSV 报告 |
| `USAGE.txt` | 简明上手指南（中英双语） |
| `README.md` | 本文件（完整中文文档） |
| `README_EN.md` | 完整英文文档 |
| `LICENSE` | MIT 许可证 |

## 许可证

MIT License - 见 [LICENSE](LICENSE)

## 链接

- [GitHub 主页](https://github.com/tomthenpc/disk-scan)
- [问题反馈](https://github.com/tomthenpc/disk-scan/issues)
