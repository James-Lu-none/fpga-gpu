# Vivado GUI 操作指南與組態筆記

本檔案記錄 Vivado GUI 建立 `fpga-gpu` 專案與 Block Design (`design_1`) 的 Step-by-Step 操作步驟。

---

## 步驟 1：匯入 Verilog 與 XDC 檔案至 Vivado 專案

1. 打開 Vivado GUI 並載入 `fpga-gpu.xpr`。
2. 左側 **Flow Navigator** ➔ **Project Manager** ➔ 點選 **Add Sources**。
3. 選擇 **Add or create design sources** ➔ 點擊 **Next**。
4. 點擊 **Add Files** ➔ 選取 `rtl/` 目錄下的 `.v` 檔案（**不要勾選** Copy sources into project）➔ 點擊 **Finish**。
5. 再次點擊 **Add Sources** ➔ 選擇 **Add or create constraints** ➔ 點擊 **Next**。
6. 點擊 **Add Files** ➔ 選取 `constrs/pcie.xdc`（**不要勾選** Copy sources into project）➔ 點擊 **Finish**。

---

## 步驟 2：在 Block Design 中建立系統 (`design_1`)

1. 打開你的 **Block Design** (`design_1`)。
2. 點擊畫布上的 **`+` (Add IP)** ➔ 搜尋並加入 `DMA/Bridge Subsystem for PCI Express` (XDMA)。
3. 雙擊 **XDMA IP** 進行圖形化配置：
   - **Basic 頁籤**：
     - Mode: `DMA`
     - Lane Width: `X2` (AX7A200B 走 PCIe Gen2 x2)
     - Link Speed: `5.0 GT/s` (PCIe 2.0)
     - Reference Clock: `100 MHz`
     - AXI Data Width: `64 bit`
     - AXI Clock Frequency: `125 MHz`
   - **PCIe: BARs 頁籤**：
     - 勾選 **PCIe to AXI Lite Master Interface**
     - BAR0: Size `64 KB`, 64-bit Non-Prefetchable
   - **PCIe: Misc 頁籤**：
     - 勾選 **MSI 64-bit**
     - Number of User Interrupts: `1`
4. 在 Block Design 畫布空白處點擊右鍵 ➔ 選擇 **Add Module...** ➔ 選取 `vgpu_top`。

---

## 步驟 3：連線與 Address Editor 設定

1. **XDMA IP 模式設定**：
   - 在 XDMA IP 的 **Basic 頁籤**，將 Interface Interface 設為 **AXI Stream**（產生 `M_AXIS_H2C_0` 與 `S_AXIS_C2H_0`）。
2. **訊號連線 (Block Design Wiring)**：
   - **AXI-Lite MMIO 控制介面**：`xdma_0/M_AXI_LITE` ──> `vgpu_top/s_axi_ctrl`
   - **AXI-Stream 下行資料串流 (H2C)**：`xdma_0/M_AXIS_H2C_0` ──> `vgpu_top/s_axis_dma`
   - **AXI-Stream 上行資料串流 (C2H)**：`vgpu_top/m_axis_dma` ──> `xdma_0/S_AXIS_C2H_0`
   - **MSI 中斷觸發訊號**：
     - `vgpu_top/usr_irq_req` ──> `xdma_0/usr_irq_req[0]`
     - `xdma_0/usr_irq_ack[0]` ──> `vgpu_top/usr_irq_ack`
   - **時脈與重置 (Clock & Reset)**：
     - `xdma_0/axi_aclk` ──> 接至 `vgpu_top/axi_aclk`
     - `xdma_0/axi_aresetn` ──> 接至 `vgpu_top/axi_aresetn`
3. **外部引腳 (External Ports)**：
   - 將 `xdma_0` 的 `sys_clk`、`sys_rst_n` 與 `pcie_mgt` 右鍵設為 **Make External**。
4. **Address Editor**：
   - 確保 `s_axi_ctrl` 映射在 `0x4000_0000` (64KB)。

---

## 步驟 4：產生 Bitstream

1. 在 Block Design `design_1` 上點右鍵 ➔ **Create HDL Wrapper** ➔ 選擇 *Let Vivado manage wrapper*。
2. 點擊左下角 **Generate Bitstream** 即可完成編譯！