# NVDLA 项目架构与调试 Agent 上下文规则 (Project Rules)

本文档为当前 NVDLA 硬件设计与微架构调试的核心规则与知识库。任何在本项目下启动的 Antigravity Agent 会话均会自动加载本上下文。

---

## 1. 项目核心背景与目标
- **目标算子**：`conv_8x8_fc_int16`（全连接/矩阵乘退化用例），位于 `hw/verif/traces/traceplayer/conv_8x8_fc_int16/`。
- **终极改造方向**：基于 CACC 16-to-1 加法树在普通卷积与 Depthwise 卷积中的利用率失衡（Depthwise 下仅 6.25%），设计**可重构加法树（4 组 4-to-1 动态切分）**。

---

## 2. 内存布局与访存协议（关键微架构认知）
1. **输入特征图（Feature Map，0x8000_0000 起始）**：
   - 形状：$H=8, W=8, C=32$，数据格式为 **有符号 INT16（Signed 16-bit，补码）**。
   - **步长参数**：`LINE_STRIDE = 0x100`（256 字节 = 8 像素 × 16 通道 × 2 字节），`SURF_STRIDE = 0x800`（2048 字节 = 8 行 × 256 字节）。
   - **DDR 返回格式（512-bit beat，32 个 INT16）**：
     - **每拍返回的是相邻 2 个空间像素的前 16 个通道（$C=0\sim 15$）**，而不是单个像素的 32 通道！
     - 对应像素的后 16 个通道（$C=16\sim 31$）位于 Surface 1，在地址偏移 `+0x800` 处发起二次读取。
   - **CBUF 写入格式**：CDMA 将读取的数据聚合为 1024-bit 宽度（64 个 INT16）写入 CBUF。

2. **卷积核权重（Weights，0x8010_0000 起始）**：
   - 形状：16 个卷积核（$K=0\sim 15$），每个尺寸 $8\times 8\times 32$，**有符号 INT16**。
   - 与特征图地址相差 `0x10_0000`（1MB 空间隔离）。
   - **最内层布局**：最内层打包 16 个输出通道（Kernels $0\sim 15$）。
   - **DDR 返回格式**：连续线性跨步（步长 0x100），每拍 512-bit 返回 2 组 (空间/输入通道) × 16 组输出 Kernel 权重。

3. **乘法阵列（CMAC）与符号数属性**：
   - `input_feature_map.dat` 与 `input_weight.dat` 均为补码有符号数。
   - CMAC 乘法单元（`NV_NVDLA_CMAC_CORE_mac.v`）采用 **Booth Radix-4 有符号乘法器**。

---

## 3. RTL 模块物理划分
- `u_partition_c`：包含 `u_NV_NVDLA_cdma`、`u_NV_NVDLA_cbuf`、`u_NV_NVDLA_csc`。
- `u_partition_ma` / `u_partition_mb`：包含 CMAC-A 与 CMAC-B（各 16×16 乘法阵列）。
- `u_partition_a`：包含 `u_NV_NVDLA_cacc`（16-to-1 加法树与累加器）。
- `u_partition_o`：包含 `u_NV_NVDLA_sdp`（后处理引擎与回写 MCIF）。
