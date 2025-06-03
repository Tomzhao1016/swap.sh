![版本](https://img.shields.io/badge/版本-v1.6.3-blue)
![平台](https://img.shields.io/badge/Platform-Linux-green.svg)
![语言](https://img.shields.io/badge/Shell-Bash-lightgrey.svg)
![许可证](https://img.shields.io/badge/License-GPLv3-blue.svg)
![作者](https://img.shields.io/badge/Author-Cloudream%20Innovation-orange.svg)

一份功能强大、安全易用的 Linux Swap（交换空间）一键管理脚本。无论您是新手还是经验丰富的系统管理员，它都能帮助您轻松、高效地设置和管理 Swap，支持交换文件和交换分区两种模式，并内置多种智能检测和安全防护机制。

---

## 📖 简介 (Introduction)

在 Linux 系统管理中，正确配置 Swap 是确保系统稳定性和性能的关键一环。然而，手动创建和管理 Swap 的过程涉及多个命令，容易出错。此脚本旨在将整个流程自动化，通过一个简单的交互式菜单或命令行参数，即可完成所有操作。

脚本的核心设计理念是**安全第一、用户友好**，它适用于几乎所有 Linux 发行版和各类虚拟化环境（如 KVM, LXC, OpenVZ 等）。

## ✨ 功能亮点 (Features)

* **🚀 高效创建与智能模式**:
    * 支持创建**交换文件** (Swap File)：优先使用 `fallocate` 快速分配，对 `Btrfs` 等特殊文件系统自动回退到 `dd` 以确保兼容性。
    * 支持将现有**物理分区**格式化为 Swap 分区。
    * 提供清晰的**交互式菜单**，可根据系统内存自动推荐最佳 Swap 大小。
    * 支持丰富的**非交互式命令行参数**，方便自动化和高级用户。
* **🛡️ 安全至上**:
    * **Root权限检查**: 自动检测并要求 root 权限运行。
    * **防止误格式化整盘**: 对格式化分区操作，会增强识别是否为整个磁盘，并进行二次强确认。
    * **操作前摘要确认**: 在交互模式下，执行关键操作前显示摘要并请求最终确认。
    * **fstab 自动管理与备份**:
        * 自动添加/删除 Swap 条目到 `/etc/fstab`，确保开机自启。
        * 优先使用 **UUID** 挂载 Swap 分区，提高系统稳定性。
        * 修改 `/etc/fstab` 前会自动创建带时间戳的备份，并支持在更新失败时从备份恢复。
        * 自动清理旧的 `fstab` 备份 (默认保留5个)。
    * **安全临时文件**: 所有临时文件均通过 `mktemp` 安全创建。
    * **UUID 校验**: 自动校验从 `blkid` 获取的 UUID 格式。
* **💻 全面兼容与智能检测**:
    * **环境检测**: 自动识别 KVM, LXC, OpenVZ 等多种虚拟化环境，并对受限的容器环境给出警告。
    * **依赖检查与自动安装**: 运行前自动检查所有必需的系统命令，并在用户同意后尝试自动安装缺失依赖 (支持 `apt`, `dnf`, `yum`)。
    * **`grep` 精确匹配**: 在检查活动Swap状态时使用更精确的正则表达式匹配。
* **⚙️ 内核参数调优**:
    * 支持配置 `vm.swappiness` 内核参数，并将其持久化到 `/etc/sysctl.d/`。
    * 能够检测系统是否存在 SSD，并据此提供 `swappiness` 的建议值。
* **📝 详细日志**: 所有操作步骤和错误信息都会记录在独立的日志文件中 (`/tmp/`目录下)，便于审计和排查问题。

## ⚙️ 环境要求 (Prerequisites)

1.  **操作系统**: 所有主流 Linux 发行版 (e.g., Ubuntu, CentOS, Debian, Fedora, Arch Linux, etc.)
2.  **运行权限**: `root` 用户或拥有 `sudo` 权限。
3.  **必需命令**: 脚本会自动检查以下命令是否存在，并在需要时提示安装：
    `swapon`, `swapoff`, `mkswap`, `free`, `df`, `awk`, `sed`, `grep`, `file`, `blkid`, `tail`, `dirname`, `readlink`, `mktemp`, `mv`, `cp`, `rm`, `chmod`, `dd`, `sysctl`, `diff` (通常预装)。`lsblk` 或 `fdisk` 至少需要一个。

## 🚀 使用方法 (Usage)

### 1. 下载脚本

您可以通过 `git` 克隆本项目：
```bash
git clone https://github.com/Tomzhao1016/swap.sh.git
cd swap.sh
```
或者，直接下载脚本文件 (脚本名为 `swap.sh`)：
```bash
curl -sLo swap.sh https://raw.githubusercontent.com/Tomzhao1016/swap.sh/main/swap.sh
```
或者使用 jsDelivr CDN 加速下载:
```bash
curl -sLo swap.sh https://fastly.jsdelivr.net/gh/Tomzhao1016/swap.sh@main/swap.sh
```

### 2. 授予执行权限

```bash
chmod +x swap.sh
```

### 3. 运行脚本

#### 方式一：交互式菜单模式 (推荐新手)

如果您不确定如何选择，或者希望在引导下完成操作，请直接运行脚本：
```bash
sudo ./swap.sh
```
脚本将展示一个清晰的菜单，引导您完成创建、删除、配置 Swappiness 或查看 Swap 状态等所有操作。在执行如创建或格式化等关键操作前，会显示本次操作的摘要信息，并要求您进行最终确认。

#### 方式二：非交互式命令行模式

本模式适用于自动化脚本或高级用户。

**可用选项:**
| 选项                     | 参数                               | 描述                                                                                               |
| :----------------------- | :--------------------------------- | :------------------------------------------------------------------------------------------------- |
| `-h`, `--help`           | -                                  | 显示帮助信息并退出。                                                                                     |
| `-v`, `--verbose`        | -                                  | 启用详细输出模式，显示更多过程信息。                                                                         |
| `-f`, `--file`           | `SIZE`                             | 创建一个指定大小的交换文件。`SIZE` 格式如 `2G`, `1024M`, `2048` (MB)。默认路径: `/swapfile`。                  |
| `-p`, `--partition`      | `DEVICE`                           | **[危险]** 将指定分区格式化为 Swap。`DEVICE` 路径如 `/dev/sdb1`。                                          |
| `-r`, `--remove`         | `TARGET` 或 `"all"`                | 删除指定的 Swap。`TARGET` 可以是文件/设备路径，或 `"all"` (删除所有)。                                       |
| `-s`, `--show`           | -                                  | 仅显示当前系统 Swap 状态和磁盘信息。                                                                   |
| `--swappiness`           | `VALUE`                            | 非交互式设置 `vm.swappiness` (0-100)。会写入配置文件并立即生效。                                                |

**使用示例:**

* **创建一个 4GB 的交换文件 (路径为默认的 `/swapfile`)**
    ```bash
    sudo ./swap_manager.sh -f 4G
    ```

* **将分区 `/dev/sdb2` 格式化为 Swap**
    ```bash
    sudo ./swap_manager.sh -p /dev/sdb2
    ```

* **删除系统上所有的 Swap**
    ```bash
    sudo ./swap_manager.sh -r all
    ```

* **删除特定的交换文件 `/mnt/myswap.img`**
    ```bash
    sudo ./swap_manager.sh -r /mnt/myswap.img
    ```

* **仅查看当前 Swap 状态**
    ```bash
    sudo ./swap_manager.sh -s
    ```

* **非交互式设置 swappiness 为 10**
    ```bash
    sudo ./swap_manager.sh --swappiness 10
    ```

## 🛠️ 未来开发计划 (Development Plan)

本脚本将持续迭代与优化，以下是一些规划中的方向：

### ✅ 已完成特性 (v1.6.3)

* 全面的 Swap 创建、删除、管理功能 (文件与分区)。
* 智能的交互式菜单与非交互式命令行支持。
* 强大的安全机制：防误格式化整盘、fstab 自动备份与恢复、操作前摘要确认。
* 内核 `vm.swappiness` 参数的智能配置与持久化。
* 依赖自动检测与安装提示。
* Btrfs 文件系统兼容性处理。
* 详细的日志记录与用户友好的彩色输出。

### 🚧 近期计划 (v1.7.x 及后续小版本)

* **[增强] Swap 优先级管理**:
    * 允许用户在创建 Swap 时或对已存在的 Swap 设置/修改优先级。
    * 在 `swapon` 时使用 `-p <priority>` 参数，并在 `fstab` 中添加 `pri=<priority>` 选项。
* **[新增] zram/zswap 支持 (可选)**:
    * 调研并考虑加入对基于内存的压缩交换方案 (zram 或 zswap) 的配置支持，作为物理 Swap 的补充或替代。
    * 这可能需要更复杂的依赖和内核模块检查。
* **[优化] 日志文件管理**:
    * 提供命令行选项允许用户指定日志文件路径，而非固定在 `/tmp/`。
    * 考虑日志轮替或限制单个日志文件大小的简单机制。
* **[增强] 依赖安装的非交互模式**:
    * 增加类似 `--yes-to-dependencies` 或 `--install-deps` 的参数，在非交互模式下自动安装所有缺失依赖，无需任何用户确认，更适合纯自动化场景。
* **[国际化/本地化] 框架引入 (初步)**:
    * 考虑为脚本输出信息引入简单的 `gettext` 支持或类似机制，为未来的多语言支持打下基础 (虽然 Bash 做这个相对复杂)。

### 💡 远期展望

* **更广泛的系统兼容性测试**: 在更多不同类型的 Linux 发行版和边缘案例中进行测试。
* **插件化或模块化架构**: 如果功能持续增多，考虑将核心逻辑与特定功能（如 zram 配置）分离，使代码更易维护和扩展。
* **简单的 Web UI (可选/实验性)**: 通过简单的 CGI 或 Python Web 框架为脚本提供一个极简的 Web 操作界面 (这是一个非常远期的想法，仅作展望)。
* **集成到更大型的系统管理工具集**: 作为某个自动化运维平台或工具链中的一个组件。

我们欢迎社区的反馈和贡献，共同完善这个工具！

## ⚠️ 重要安全警告 (Important Safety Warnings)

1.  **Root 权限**: 本脚本必须以 `root` 权限运行。所有操作都将直接对系统产生影响。
2.  **数据丢失风险**:
    > **❗️❗️❗️ 使用 `-p` 或 `--partition` 选项（或交互菜单中对应的功能）将会格式化指定的分区，该分区上的所有数据都将被永久删除！脚本已内置针对误格式化整个磁盘的强验证，但请务必在执行此操作前，再三确认设备路径无误且数据已备份。**
3.  **备份与恢复**: 脚本在修改 `/etc/fstab` 前会自动备份。备份文件优先存储在 `/var/backups` 目录，其次是 `/etc/` 目录。如果系统因 `fstab` 配置错误无法启动，您可以使用 `LiveCD/USB` 环境，通过这些备份文件进行手动恢复。脚本在 `/etc/fstab` 更新失败时也会尝试提示从备份恢复。

## 🤝 如何贡献 (How to Contribute)

欢迎您为这个项目做出贡献！我们鼓励任何形式的贡献，包括：
* **报告 Bug**: 通过项目的 GitHub Issues (如果项目已发布到 GitHub) 提交您发现的问题。
* **提出建议**: 对新功能或改进有任何想法，欢迎创建 Issue 进行讨论。
* **提交代码 (Pull Requests)**:
    1.  Fork 本项目 (如果项目已发布到 GitHub)。
    2.  创建您的特性分支 (`git checkout -b feature/AmazingFeature`)。
    3.  提交您的修改 (`git commit -m 'Add some AmazingFeature'`)。
    4.  推送至您的分支 (`git push origin feature/AmazingFeature`)。
    5.  打开一个 Pull Request。

请尽量保持代码风格与项目现有代码一致。

## 📄 许可证 (License)

本项目基于 **GNU 通用公共许可证 v3.0 (GPLv3)** 开源。

简单来说，这意味着您可以自由地运行、研究、分享和修改这个软件。但是，任何基于此代码分发的衍生作品或修改版本，**也必须同样以 GPLv3 许可证开源**。

完整的许可证文本请参阅项目根目录下的 `LICENSE` 文件。

## 👨‍💻 作者 (Author)

**[Cloudream Innovation](https://www.cloudream.top)**