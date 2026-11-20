# NVDLA 硬件仿真与运行操作指南

> 本文档专注于 **NVDLA 硬件环境的搭建、VCS + Verdi 仿真验证与波形调试操作**。
> - 核心算子时序与波形精读：👉 [NVDLA_8x8乘加算子深度研读指南.md](NVDLA_8x8乘加算子深度研读指南.md)
> - 硬件微架构剖析与改造设计：👉 [NVDLA微架构剖析与改造指南.md](NVDLA微架构剖析与改造指南.md)

---

## 目录

- [一、 软硬件环境依赖](#一-软硬件环境依赖)
- [二、 目录结构概览](#二-目录结构概览)
- [三、 快速上手：VCS + Verdi 一键仿真](#三-快速上手vcs--verdi-一键仿真)
- [四、 官方可选测试算子与仿真方式全清单](#四-官方可选测试算子与仿真方式全清单)
- [五、 仿真验证机制：Trace-Player 原理解析](#五-仿真验证机制trace-player-原理解析)
- [六、 常见排错与运行问答（FAQ）](#六-常见排错与运行问答faq)

---

## 一、 软硬件环境依赖

本工程推荐在 **Linux (Ubuntu 18.04 / 20.04 或 CentOS / RHEL 7+)** 服务器环境下运行。

### 1. 工具链版本要求

| 工具 / 软件         | 推荐版本                      | 用途说明                              |
| :------------------ | :---------------------------- | :------------------------------------ |
| **VCS**       | 2018.09 / 2020.03 及以上      | 硬件 RTL 编译与 UVM Testbench 仿真    |
| **Verdi**     | 2018.09 / 2020.03 及以上      | 源码结构浏览、FSDB 波形查看与信号调试 |
| **GCC / G++** | 4.8 ~ 7.x (系统自带)          | 编译 VCS C++ 仿真中间产物             |
| **Java**      | OpenJDK 8 / Oracle JDK 1.8    | 运行寄存器生成工具（ordt）            |
| **Perl**      | 5.16+ (带 YAML, IO::Tee 模块) | 执行 `tmake` 树形构建与测试脚本     |

### 2. 基础依赖包安装（以 Ubuntu 为例）

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential gcc g++ clang make perl \
    libyaml-perl libio-tee-perl openjdk-8-jdk flex bison
```

---

## 二、 目录结构概览

```text
NVDLA/
├── README.md                            # ★ 本文件（运行与仿真操作指南）
├── NVDLA微架构剖析与改造指南.md        # ★ 学习笔记、微架构剖析与加法树改造设计
├── 数字前端工程师AI加速芯片路线规划.md   # 转型实战路线图与面试考点梳理
└── hw/                                  # NVDLA 硬件工程源码
    ├── run_vcs.sh                       # ★ 一键快速仿真脚本（自动编译/回归/弹Verdi）
    ├── outdir/                          # 生成的目标目录 (outdir/nv_full/vmod)
    ├── tools/                           # 构建工具链 (tmake, defgen, eperl 等)
    ├── vmod/                            # Verilog RTL 源码与库单元
    │   ├── nvdla/                       # NVDLA 核心模块 (cmac, cacc, cdma, csc, sdp 等)
    │   ├── vlibs/                       # 基础逻辑单元库
    │   └── rams/                        # SRAM 行为级模型
    └── verif/                           # 验证套件
        ├── sim/                         # ★ VCS + UVM 仿真工程 (含 Makefile)
        ├── traces/traceplayer/          # 官方 Golden 测试激励包 (sanity, conv, googlenet 等)
        └── verilator/                   # 开源 Verilator C++ 仿真器 (备用)
```

---

## 三、 快速上手：VCS + Verdi 一键仿真

为避免官方原生脚本中路径写死和配置文件被覆盖的问题，工程提供了封装好的 **`hw/run_vcs.sh`** 脚本。

### 1. 准备工作

将工程同步到 Linux 服务器后，进入 `hw/` 目录并赋予脚本执行权限：

```bash
cd hw
chmod +x run_vcs.sh
```

### 2. 核心执行命令

#### (1) 默认跑冒烟测试（sanity0）

```bash
./run_vcs.sh
```

*自动检查环境变量、生成 RTL、调用 VCS 编译 Testbench 并运行用例。比对无误后终端输出 `checktest: PASSED`。*

#### (2) 仿真完成后自动调出 Verdi 查看波形与源码

```bash
./run_vcs.sh -gui
```

*仿真执行结束后，自动唤起 Verdi GUI 窗口，加载 `dut.f` 源码树和当前测试的 `debussy.fsdb` 波形。*

#### (3) 运行指定算子测试并看波形

```bash
# 运行 8x8 卷积/全连接测试 + 弹 Verdi
./run_vcs.sh -t conv_8x8_fc_int16 -gui

# 运行 GoogleNet 3x3 卷积测试 + 弹 Verdi
./run_vcs.sh -t googlenet_conv2_3x3_int16 -gui
```

#### (4) 清理仿真产物

```bash
./run_vcs.sh -clean
```

---

## 四、 官方可选测试算子与仿真方式全清单

### 1. 官方 12 个 Trace 测试用例完整清单

所有测试用例均位于 `hw/verif/traces/traceplayer/` 目录下，涵盖**基础通路、独立算子引擎、真实神经网络卷积层**，均可通过 `./run_vcs.sh -t <用例名> -gui` 直接一键运行并查看 FSDB 波形：

#### (1) 独立算子级测试（针对具体硬件引擎）
| 测试用例名 | 对应硬件引擎 | 算子功能与测试场景 | 一键仿真与看波形命令 |
|:---|:---|:---|:---|
| **`conv_8x8_fc_int16`** | CMAC + CACC | **全连接 / 矩阵乘（GEMM）**：16-bit 定点 $8\times 8$ 乘加与规约累加 | `./run_vcs.sh -t conv_8x8_fc_int16 -gui` |
| **`sdp_relu_int16`** | SDP (单数据处理器) | **激活函数算子**：16-bit ReLU 非线性映射、阈值截断与饱和 | `./run_vcs.sh -t sdp_relu_int16 -gui` |
| **`pdp_max_pooling_int16`**| PDP (平面数据处理器) | **池化算子**：空间最大池化（Max Pooling）下采样流水线 | `./run_vcs.sh -t pdp_max_pooling_int16 -gui` |

#### (2) 真实深度学习网络卷积层测试（端到端经典算子）
| 测试用例名 | 对应硬件引擎 | 算子功能与测试场景 | 一键仿真与看波形命令 |
|:---|:---|:---|:---|
| **`googlenet_conv2_3x3_int16`** | 全通路卷积引擎 | **GoogleNet 经典卷积层**：真实 $3\times 3$ 卷积滑窗、权重加载与特征图输出 | `./run_vcs.sh -t googlenet_conv2_3x3_int16 -gui` |
| **`cc_alexnet_conv5_relu5_int16_dtest_cvsram`** | 全通路 + SDP | **AlexNet Conv5 + ReLU 融合算子**：片上 CVSRAM 模式下的高吞吐融合计算 | `./run_vcs.sh -t cc_alexnet_conv5_relu5_int16_dtest_cvsram -gui` |

#### (3) 基础冒烟与存储通路测试（Sanity 通路）
| 测试用例名 | 对应硬件引擎 | 测试目的 | 一键仿真与看波形命令 |
|:---|:---|:---|:---|
| **`sanity0`** | CSB / 全局控制 | CSB 配置总线握手、内部状态寄存器读写 | `./run_vcs.sh -t sanity0 -gui` |
| **`sanity1`** | BDMA / DRAM | 外部 DDR 内存读写与数据搬运通路 | `./run_vcs.sh -t sanity1 -gui` |
| **`sanity1_cvsram`** | BDMA / CVSRAM | 片上静态 SRAM（CVSRAM）高速搬运通路 | `./run_vcs.sh -t sanity1_cvsram -gui` |
| **`sanity2`** | CDMA + CBUF + CSC | 外部 DRAM 模式下的卷积控制与存储分发 | `./run_vcs.sh -t sanity2 -gui` |
| **`sanity2_cvsram`** | CDMA + CBUF + CSC | 片上 CVSRAM 模式下的卷积控制与存储分发 | `./run_vcs.sh -t sanity2_cvsram -gui` |
| **`sanity3`** | 完整卷积级联 (DRAM) | CDMA $\to$ CMAC $\to$ CACC $\to$ SDP 全链路 | `./run_vcs.sh -t sanity3 -gui` |
| **`sanity3_cvsram`** | 完整卷积级联 (SRAM) | CDMA $\to$ CMAC $\to$ CACC $\to$ SDP (SRAM 模式) | `./run_vcs.sh -t sanity3_cvsram -gui` |

---

### 2. 所有的可选仿真与调试工作流方式

根据数字前端与芯片验证的不同场景需求，支持以下 5 种常用仿真方式：

#### 方式一：一键自动化仿真 + 自动唤起 Verdi GUI（日常单算子精细调试）
- **特点**：自动编译、运行仿真并导出 FSDB，比对完成后自动弹出 Verdi 窗口加载源码与波形。
- **命令**：
  ```bash
  ./run_vcs.sh -t conv_8x8_fc_int16 -gui
  ```

#### 方式二：纯命令行后台静默仿真（适合长时间运行或批量脚本）
- **特点**：静默运行不打断终端，波形自动保存在对应测试目录的 `debussy.fsdb`，随时可手动调出查看。
- **命令**：
  ```bash
  # 1. 运行仿真并导出波形
  ./run_vcs.sh -t googlenet_conv2_3x3_int16

  # 2. 随时手动调出 Verdi 查看波形
  cd verif/sim
  verdi -sv -f dut.f -ssf googlenet_conv2_3x3_int16/debussy.fsdb &
  ```

#### 方式三：底层 Makefile 精细化控制模式（原生高级调试模式）
- **特点**：直接在 `verif/sim` 目录下调用原生规则，支持分步独立编译、运行与单独起 Verdi。
- **命令**：
  ```bash
  cd verif/sim
  make build DUMP=1 DUMPER=VERDI                                        # 单独编译
  make run DUMP=1 DUMPER=VERDI TESTDIR=../traces/traceplayer/sdp_relu_int16 # 单独运行
  make verdi TESTDIR=../traces/traceplayer/sdp_relu_int16                   # 单独调起波形
  ```

#### 方式四：批量回归测试模式（Regression 模式）
- **特点**：修改 RTL（如改动 CACC 加法树或 CDMA 缓冲区）后，一键自动串行跑完所有用例并输出汇总通过率报表。
- **命令**：
  ```bash
  cd verif/sim
  make regress
  ```

#### 方式五：功耗分析仿真模式（生成 SAIF 开关活动率文件）
- **特点**：记录硬件网络翻转率（Toggle Rate），生成 `.saif` 文件供 Synopsys PrimeTime-PX (PTPX) 评估动态功耗与门控时钟收益。
- **命令**：
  ```bash
  cd verif/sim
  make run SAIF=1 TESTDIR=../traces/traceplayer/conv_8x8_fc_int16
  ```

---

## 五、 仿真验证机制：Trace-Player 原理解析

NVDLA 硬件采用了业界轻量且高效的 **Trace-Player（事务流回放比对）** 验证模式：

```text
                     ┌──────────────────────────────────────────┐
                     │  hw/verif/traces/traceplayer/<testname>  │
                     └─────────────────────┬────────────────────┘
                                           │
                        load_mem / write_reg / read_reg
                                           │
                                           ▼
┌──────────────────┐               ┌───────────────┐               ┌──────────────────┐
│   片外虚拟内存    │ <--- AXI ---> │  NVDLA RTL    │ <--- CSB ---> │ Testbench (TB)   │
│ (DRAM / CVSRAM)  │               │ (DUT 核心硬件) │               │ (Trace Player)   │
└────────┬─────────┘               └───────────────┘               └──────────────────┘
         │
         │ dump_mem (计算结束后将输出特征图读出)
         ▼
┌───────────────────────────────────────────────────────────────┐
│ 与预存 Golden 数据逐字节比对: if (rtl_data != golden_data)     │
│  => 全部一致输出: checktest: PASSED                            │
└───────────────────────────────────────────────────────────────┘
```

- **`load_mem`**：自动将输入特征图与权重文件加载进片外内存空间；
- **`write_reg`**：通过 CSB 总线配置模块寄存器参数，触发硬件执行；
- **`read_reg`**：轮询中断与状态寄存器，等待计算完成；
- **`dump_mem`**：将 RTL 计算结果输出至内存，与预存 Golden 结果进行 **逐字节严格一致性比对**。

---

## 六、 常见排错与运行问答（FAQ）

### Q1：仿真报错提示 `novas.tab` 或 `pli.a` 找不到？

**解答**：这是由于未设置 Verdi 环境变量。`run_vcs.sh` 依赖系统 PATH 中的 `verdi` 命令（即 `which verdi`）。请确保在终端中先加载好 EDA module（如 `module load verdi`）或已 `export PATH=$VERDI_HOME/bin:$PATH`。

### Q2：编译时提示缺少 Synopsys DesignWare 许可证？

**解答**：工程已在 `hw/verif/sim/Makefile` 中设置了 `DESIGNWARE_NOEXIST ?= 1`。该参数会自动使用 `vmod/vlibs/` 下开源的行为级模型替代商业 DesignWare 库，**无需商业 DW License 即可正常编译运行**。

### Q3：为什么不能直接运行官方的 `tools/bin/run_sanity`？

**解答**：官方 `run_sanity` 脚本第 19 行会强行执行 `cp tools/make/tree.make.vm tree.make`，覆盖掉自定义的路径配置；且原厂 Makefile 内部写死了 NVIDIA 内部机器路径。请始终使用封装好的 `hw/run_vcs.sh`。
