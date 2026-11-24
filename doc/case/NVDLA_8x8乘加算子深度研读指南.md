# NVDLA 8×8 乘加算子（conv_8x8_fc_int16）深度研读与波形调试指南

> 🎯 **研读目标**：以 `conv_8x8_fc_int16` 用例为切入点，通过 **“数学模型 $\to$ 寄存器配置 $\to$ 硬件数据流流动 $\to$ Verdi 波形信号精析”** 四位一体的方法，彻底吃透 NVDLA 从片外访存、乘加阵列、加法树规约到数据后处理的完整 ASIC 硬件流水线，为后续进行 **Depthwise 可重构加法树改造** 打下最坚实的基础。

---

## 目录

- [一、 算子档案：数学本质与计算量剖析](#一-算子档案数学本质与计算量剖析)
- [二、 硬件端到端生命周期六步曲（数据流总览）](#二-硬件端到端生命周期六步曲数据流总览)
- [三、 CSB 寄存器配置全流程解密（input.txn 导读）](#三-csb-寄存器配置全流程解密inputtxn-导读)
- [四、 Verdi 波形核心信号必抓清单（实战调试）](#四-verdi-波形核心信号必抓清单实战调试)
- [五、 RTL 核心源码逐级精读路线](#五-rtl-核心源码逐级精读路线)
- [六、 思考与启发：从 8×8 算子迈向加法树改造](#六-思考与启发从-88-算子迈向加法树改造)

---

## 一、 算子档案：数学本质与计算量剖析

### 1. 为什么叫 `conv_8x8_fc_int16`？
- **输入特征图（Feature Map）**：
  $H_{in} = 8, W_{in} = 8, C_{in} = 32$（高 8、宽 8、输入通道 32），数据类型为 **INT16**（每个数据占 2 字节）。
  - 总输入大小：$8 \times 8 \times 32 \times 2 = 4096\text{ 字节 (4KB)}$，物理地址起始于 `0x80000000`。
- **卷积核权重（Weights）**：
  拥有 16 个卷积核（$C_{out} = 16$），每个卷积核的尺寸为 $8 \times 8 \times 32$。
  - 物理地址起始于 `0x80100000`。
- **输出特征图（Output）**：
  当卷积核尺寸等于输入图像空间尺寸（$8\times 8$）且没有 Padding 时，卷积操作在数学上**完全退化为一个标准的全连接层（Fully Connected / GEMM 矩阵乘）**！
  - 输出尺寸为：$1 \times 1 \times 16$（1 个空间像素，16 个输出通道）。
  - 总输出大小：$1 \times 1 \times 16 \times 2 = 32\text{ 字节 (0x20)}$，物理地址写回至 `0x80400000`。

### 2. 核心计算量
- **总乘加次数（MACs）**：
  $$\text{Total MACs} = H_{out} \times W_{out} \times C_{out} \times (K_h \times K_w \times C_{in}) = 1 \times 1 \times 16 \times (8 \times 8 \times 32) = 32,768\text{ 次乘加}$$
- NVDLA 的 CMAC 阵列在 INT16 模式下一拍可并发执行 **256 次乘法**。因此在理想无气泡流水线下，纯计算仅需：
  $$T_{compute} = \frac{32,768}{256} = 128\text{ 个计算时钟周期}$$

### 3. DDR 内存布局与访存微架构精析
- **数据格式**：`input_feature_map.dat` 与 `input_weight.dat` 均为 **有符号数（Signed INT16，二进制补码）**；CMAC 乘法器内部采用 **Booth Radix-4 有符号乘法算法**。
- **特征图内存布局（Surface / Line 组织）**：
  - `LINE_STRIDE = 0x100`（256 字节 = 8 像素 × 16 通道 × 2 字节）；
  - `SURF_STRIDE = 0x800`（2048 字节 = 8 行 × 256 字节）；
  - **DDR 512-bit 返回拍结构**：每拍返回 32 组 INT16 数据，对应 **相邻 2 个空间像素的前 16 个通道（$C=0\sim 15$）**，而非 1 个像素的 32 通道！后 16 个通道存放在 Surface 1（地址偏移 `+0x800`）。
  - **CBUF 写入**：CDMA 在片内将读入的数据汇聚拼装为 1024-bit 宽度（64 个 INT16）写入 CBUF。
- **权重内存布局（0x8010_0000 起始）**：
  - 与特征图地址间隔 `0x10_0000`（1MB 空间隔离）；
  - 最内层维度打包 16 个输出卷积核（$K=0\sim 15$）；读请求地址连续线性递增（跨步 `0x100`），每拍 512-bit 返回 2 组空间权重 × 16 个输出 Kernel。

---

## 二、 硬件端到端生命周期六步曲（数据流总览）

运行该算子时，NVDLA 内部硬件经历了以下 6 个严格的时序阶段：

```text
  [阶段 1: 内存灌入]   AXI 虚拟内存加载 input_feature_map.dat 与 input_weight.dat
           │
           ▼
  [阶段 2: 寄存器配置] CSB 依次向 CDMA、CSC、CMAC、CACC、SDP 下发尺寸与地址参数
           │
           ▼
  [阶段 3: 触发启动]   软件向各引擎写入 D_OP_ENABLE_0=1，触发硬件调度互锁状态机
           │
           ▼
  [阶段 4: 计算流水线流动]
       CDMA 读入特征图与权重 ──► 存入 CBUF (Data/Weight Bank 独立切分)
                                     │
                                    CSC 按节拍向 CMAC-A / CMAC-B 广播数据
                                     │
                                    CMAC 执行 16×16 乘法操作
                                     │
                                    CACC 16-to-1 加法树规约 + abuf 部分和累加
                                     │
                                    SDP 线性缩放截断，通过 AXI 写回内存
           │
           ▼
  [阶段 5: 中断流水线通知] 硬件状态机依次上报 4 级中断:
       CDMA_DAT_DONE ──► CDMA_WT_DONE ──► CACC_DONE ──► SDP_DONE
           │
           ▼
  [阶段 6: 结果校验] dump_mem 读出 0x80400000 处的 32 字节数据，与 output_feature_map.dat 逐字节比对
```

---

## 三、 CSB 寄存器配置全流程解密（input.txn 导读）

打开 `hw/verif/traces/traceplayer/conv_8x8_fc_int16/input.txn`，你可以清晰地观察到驱动这颗芯片的每一个寄存器动作：

### 1. CDMA（张量 DMA）参数配置（Line 5 ~ 82）
- `D_MISC_CFG_0 (0xffff1405)`：写入 `0x11001100` $\to$ 配置输入与权重均为 **INT16** 精度；
- `D_DATAIN_SIZE_0_0 (0xffff1407)`：写入 `0x70007` $\to$ 配置输入高宽 $H-1=7, W-1=7$（即 $8\times 8$）；
- `D_DATAIN_SIZE_1_0 (0xffff1408)`：写入 `0x1f` $\to$ 配置输入通道 $C-1=31$（即 32 通道）；
- `D_DAIN_ADDR_LOW_0_0 (0xffff140d)`：写入 `0x80000000` $\to$ 特征图物理地址；
- `D_WEIGHT_ADDR_LOW_0 (0xffff141f)`：写入 `0x80100000` $\to$ 权重物理地址；
- `D_BANK_0 (0xffff142f)`：写入 `0x20001` $\to$ 为数据分配 1 个 CBUF Bank，为权重分配 2 个 Bank。

### 2. CSC（卷积序列发生器）配置（Line 83 ~ 124）
- `D_WEIGHT_SIZE_EXT_0_0 (0xffff180b)`：写入 `0x70007` $\to$ 卷积核尺寸 $8\times 8$；
- `D_DATAOUT_SIZE_1_0 (0xffff1810)`：写入 `0xf` $\to$ 输出通道数 $16-1=15$。

### 3. CMAC 阵列与 CACC 累加器配置（Line 125 ~ 154）
- `D_MISC_CFG_0 (0xffff1c03 / 0xffff2003)`：配置 CMAC-A / CMAC-B 工作在 INT16 模式；
- `D_DATAOUT_ADDR_0 (0xffff2406)`：写入输出目标缓冲地址；
- `D_DATAOUT_SIZE_0_0 (0xffff2404)`：输出空间尺寸为 $1\times 1$。

### 4. SDP（后处理引擎）配置（Line 155 ~ 212）
- `D_FEATURE_MODE_CFG_0 (0xffff2c2c)`：写入 `0x1` $\to$ 开启 Flying 模式（即数据从 CACC 直接飞流进 SDP，不落 DRAM）；
- `D_DST_BASE_ADDR_LOW_0 (0xffff2c12)`：写入 `0x80400000` $\to$ 最终结果回写 DDR 的物理地址；
- `D_CVT_SCALE_0 (0xffff2c31)`：写入 `0x1` $\to$ 缩放系数为 1（直通，不做截断压缩）。

### 5. 触发与四级中断轮询（Line 213 ~ 240）
```text
write_reg D_OP_ENABLE_0 0x1    # 同时拉高各个引擎的使能
wait
read_reg S_INTR_STATUS_0 ...   # 1. CDMA_DAT_DONE (数据已进 CBUF)
read_reg S_INTR_STATUS_0 ...   # 2. CDMA_WT_DONE  (权重已进 CBUF)
read_reg S_INTR_STATUS_0 ...   # 3. CACC_DONE     (32768次MAC与加法累加结束)
read_reg S_INTR_STATUS_0 ...   # 4. SDP_DONE      (结果已写回 DDR)
dump_mem 0x80400000 0x20 ...   # 比对 32 字节 Golden 结果
```

---

## 四、 Verdi 波形核心信号必抓清单（实战调试）

当在终端通过 `./run_vcs.sh -t conv_8x8_fc_int16 -gui` 调出 Verdi 后，点击 **`Tools -> New Waveform`**，按快捷键 **`g`** 将以下关键信号拉入波形窗口：

### 1. 全局配置与中断信号（掌握算子运行时间）
| 信号路径 | 信号名称 | 观察目的 |
|:---|:---|:---|
| `top.nvdla_top` | `dla_core_clk` / `dla_reset_rstn` | 观察主时钟与复位解复位时序 |
| `top.nvdla_top` | `dla_intr` | **核心中断信号**：观察何时刻拉高代表硬件全部算完 |
| `top.nvdla_top.u_partition_c.u_NV_NVDLA_glb` | `intr_status` | 观察 4 级中断（CDMA/CACC/SDP）的逐级置位过程 |

### 2. CDMA 数据搬运与 CBUF 写入信号（访存核心）
> ⚠️ **注意真实层级**：在 NVDLA 的物理划分中，`cdma` 与 `cbuf` 均实例化在 **`u_partition_c`** 内部（而不是 `partition_m`）。

| 信号路径 | 精确 RTL 信号名称 | 观察目的 |
|:---|:---|:---|
| `top.nvdla_top.u_partition_c.u_NV_NVDLA_cdma` | **`cdma_dat2mcif_rd_req_valid`**<br>`cdma_dat2mcif_rd_req_ready`<br>`cdma_dat2mcif_rd_req_pd[78:0]` | **特征图读请求握手与命令**：CDMA 向外部 DDR (MCIF) 发起特征图读请求（`_pd[63:0]` 为 64 位物理起始地址，`_pd[78:64]` 为 15 位突发长度 `size`，单位为 32 字节原子块） |
| `top.nvdla_top.u_partition_c.u_NV_NVDLA_cdma` | **`cdma_wt2mcif_rd_req_valid`**<br>`cdma_wt2mcif_rd_req_ready`<br>`cdma_wt2mcif_rd_req_pd[78:0]` | **权重读请求握手与命令**：CDMA 向外部 DDR (MCIF) 发起权重读请求（`_pd[63:0]` 为 64 位物理起始地址，`_pd[78:64]` 为 15 位突发长度 `size`，单位为 32 字节原子块） |
| `top.nvdla_top.u_partition_c.u_NV_NVDLA_cdma` | **特征图返回**：<br>**`mcif2cdma_dat_rd_rsp_valid`**<br>`mcif2cdma_dat_rd_rsp_ready`<br>`mcif2cdma_dat_rd_rsp_pd[513:0]`<br><br>**权重返回**：<br>**`mcif2cdma_wt_rd_rsp_valid`**<br>`mcif2cdma_wt_rd_rsp_ready`<br>`mcif2cdma_wt_rd_rsp_pd[513:0]` | **DDR 数据返回握手与数据**：外部内存将特征图和权重返回给 CDMA 的 valid/ready 握手与数据信号（`_pd[511:0]` 为 512-bit 数据总线，`_pd[513:512]` 为字节掩码 mask） |
| `top.nvdla_top.u_partition_c.u_NV_NVDLA_cbuf` | **`cdma2buf_dat_wr_en`**<br>`cdma2buf_dat_wr_addr[11:0]`<br>`cdma2buf_dat_wr_data[1023:0]` | **特征图写 CBUF 缓冲**：CDMA 将读取的特征图按 1024-bit 位宽写入片上 SRAM |
| `top.nvdla_top.u_partition_c.u_NV_NVDLA_cbuf` | **`cdma2buf_wt_wr_en`**<br>`cdma2buf_wt_wr_addr[11:0]`<br>`cdma2buf_wt_wr_data[511:0]` | **权重写 CBUF 缓冲**：CDMA 将读取的权重按 512-bit 位宽写入片上 SRAM |

### 3. CMAC 乘加阵列输入与输出（核心算力观测点）
> 💡 CMAC 分为 A、B 两个独立单元，分别位于 **`u_partition_ma`** 和 **`u_partition_mb`** 中。

| 信号路径 | 精确 RTL 信号名称 | 观察目的 |
|:---|:---|:---|
| `top.nvdla_top.u_partition_ma.u_NV_NVDLA_cmac` | `sc2mac_dat_pvld`<br>`sc2mac_wt_pvld` | **输入握手**：CSC 调度器将数据和权重同步送入乘法阵列的使能信号 |
| `top.nvdla_top.u_partition_ma.u_NV_NVDLA_cmac` | **`mac2accu_pvld`** | **乘法完成指示**：CMAC 算完当前时钟节拍，向后级 CACC 输出有效脉冲 |
| `top.nvdla_top.u_partition_ma.u_NV_NVDLA_cmac` | **`mac2accu_data0 ~ data7`**<br>(每个总线 `[175:0]`) | **乘法乘积输出**：CMAC 计算出的多组乘积结果，送往 CACC 加法树 |

### 4. CACC 规约加法树与累加器（王牌微架构核心观察点）
> 💡 位于 **`u_partition_a.u_NV_NVDLA_cacc`** 中，负责把来自 CMAC-A 和 CMAC-B 的乘积进行求和。

| 信号路径 | 精确 RTL 信号名称 | 观察目的 |
|:---|:---|:---|
| `top.nvdla_top.u_partition_a.u_NV_NVDLA_cacc` | **`mac_a2accu_pvld`**<br>**`mac_b2accu_pvld`** | 接收来自 CMAC-A 和 CMAC-B 乘法阵列的输入有效信号 |
| `top.nvdla_top.u_partition_a.u_NV_NVDLA_cacc` | **`mac_a2accu_data0 ~ 7`**<br>**`mac_b2accu_data0 ~ 7`** | CACC 接收到的待累加原始乘积数据 |
| `top.nvdla_top.u_partition_a.u_NV_NVDLA_cacc` | **`accu_ctrl_valid`** | 加法树运算使能有效信号 |
| `top.nvdla_top.u_partition_a.u_NV_NVDLA_cacc` | `abuf_wr_en[7:0]`<br>`abuf_wr_data0 ~ 7` | **部分和累加锁存**：加法树规约求和后的中间结果写入 Assembly Buffer |

---

## 五、 RTL 核心源码逐级精读路线

建议在 Verdi 中配合源码，按照数据流从前到后的顺序进行精读：

```text
第 1 站: hw/vmod/nvdla/cdma/NV_NVDLA_cdma.v
  └── 理解 CDMA 如何根据 Stride 跨步将 2D/3D 张量搬入片上 CBUF。

第 2 站: hw/vmod/nvdla/csc/NV_NVDLA_csc.v
  └── 理解 CSC 时空调度器如何把 8×8 空间坐标转换为时钟周期的发射序列。

第 3 站: hw/vmod/nvdla/cmac/NV_NVDLA_cmac.v & NV_NVDLA_CMAC_CORE_mac.v
  └── 理解 16×16 MAC 乘法阵列的流水线打拍与门控时钟（ICG）控制。

第 4 站 (最关键): hw/vmod/nvdla/cacc/NV_NVDLA_cacc.v & NV_NVDLA_CACC_calculator.v
  └── 重点研读 u_calculator 内部的加法树实现结构，数一数它从输入到输出一共打了多少拍（Pipeline Latency）。

第 5 站: hw/vmod/nvdla/sdp/NV_NVDLA_sdp.v
  └── 理解 CACC 算完后的高位数据如何通过截断、定点饱和缩放，恢复为标准 INT16 并写回内存。
```

---

## 六、 思考与启发：从 8×8 算子迈向加法树改造

研读完 `conv_8x8_fc_int16` 用例后，请深入思考以下三个问题，这正是通往顶级芯片架构师的核心思考路径：

1. **为什么在 `conv_8x8` 用例中加法树利用率极高？**
   - 因为输入通道有 32 个，CACC 的 16-to-1 加法树在两个周期内满载规约 32 个通道的乘积，所有 16 个加法器输入端全都有真实数据参与运算，利用率 100%。

2. **如果把这个算子换成 MobileNet 的 Depthwise 卷积，会发生什么？**
   - Depthwise 卷积每个卷积核只有 1 个通道（$C_{in}=1$）；
   - 在 16 个乘法器中，只有 1 个乘法器在算当前通道，其余 15 个乘法器全被置 0；
   - 16-to-1 加法树只能把 1 个真实数字与 15 个 0 相加，**整棵加法树的硬件利用率瞬间跌入谷底（仅剩 6.25%）！**

3. **我们的微架构改造突破口在哪里？**
   - 既然 Depthwise 模式下不需要跨 16 个通道做求和，我们为什么不把这棵大树动态打散成 **4 组 4-to-1 小树**，让每一组小树同时去算图像上不同的 4 个像素点？
   - 只要在 `NV_NVDLA_CACC_calculator.v` 中插入两组 MUX，就能以不到 5% 的面积代价，让硬件利用率从 18.75% 翻 4 倍飙升到 75%！
