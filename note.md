# Vivado FPGA 全流程開發與業界操作筆記 (Industry Standard Handbook)

本文件紀錄從 Verilog RTL 設計、IP 封裝、Block Design 系統整合、電路分析 (Schematic/Netlist)、RTL 模擬、綜合編譯到硬體燒錄與 Git Tcl 自動化開發的全流程業界最佳實踐 (Best Practice)。

---

## 目錄
1. [階段 1：RTL 設計與代碼管理 (.v 檔案處理)](#階段-1rtl-設計與代碼管理-v-檔案處理)
2. [階段 2：AXI-Lite 樣板產生與 IP 封裝 (Create & Package IP)](#階段-2axi-lite-樣板產生與-ip-封裝-create--package-ip)
3. [階段 3：Block Design 頂層系統整合 (IP Integrator)](#階段-3block-design-頂層系統整合-ip-integrator)
4. [階段 4：電路結構分析 (Schematic & Netlist 檢視)](#階段-4電路結構分析-schematic--netlist-檢視)
5. [階段 5：RTL 功能模擬 (Behavioral Simulation)](#階段-5rtl-功能模擬-behavioral-simulation)
6. [階段 6：腳位約束與 Bitstream 綜合編譯](#階段-6腳位約束與-bitstream-綜合編譯)
7. [階段 7：硬體下載與 Flash 固化燒錄 (Hardware Manager)](#階段-7硬體下載與-flash-固化燒錄-hardware-manager)
8. [階段 8：業界 Git 版控與 Tcl 自動化工作流](#階段-8業界-git-版控與-tcl-自動化工作流)

---

## 階段 1：RTL 設計與代碼管理 (.v 檔案處理)

### 1.1 匯入外部 Verilog `.v` 原始碼
1. 左側 **Flow Navigator** ➔ **Project Manager** ➔ 點選 **Add Sources**。
2. 選擇 **Add or create design sources** ➔ 點擊 **Next**。
3. 點擊 **Add Files** ➔ 選取 `rtl/` 目錄下的 `.v` 檔案。
   * 💡 **業界建議**：**取消勾選** *Copy sources into project*，保持原始碼在獨立資料夾中，方便 Git 版控。
4. 點擊 **Finish** 完成匯入。

### 1.2 外部修改 `.v` 檔後的刷新機制 (Refresh Changed Modules)
當在外部 IDE (VS Code / Antigravity) 修改了 `.v` 檔的引腳或邏輯後，Vivado 會在 Block Design 標記為 **`Stale module reference`**。
* **刷新方式 1 (最快)**：在彈出的 **IP Status** 視窗最下方點擊 **`Upgrade Selected`** 按鈕。
* **刷新方式 2**：在 Block Design 畫布頂部的黃色警告橫幅中，點擊 **`Refresh Changed Modules`**。

---

## 階段 2：AXI-Lite 樣板產生與 IP 封裝 (Create & Package IP)

### 2.1 自動產生公版 AXI4-Lite Slave 暫存器樣板
當需要編寫 PCIe MMIO 暫存器檔時，無需手寫 AXI 握手狀態機：
1. 頂部選單 **Tools** ➔ **Create and Package New IP...** ➔ **Next**。
2. 選擇 **Create a new AXI4 peripheral** ➔ 點擊 **Next**。
3. 設定 Interface 屬性：
   * **Type**: `Slave`
   * **Protocol**: `Lite`
   * **Data Width**: `32`
   * **Number of Registers**: 設定暫存器數量（如 `8` 或 `16`）。
4. 點擊 **Finish** ➔ 選擇 **Edit IP**。
5. Vivado 會自動生成包含完美 AXI4-Lite 握手與 `case (addr)` 解碼邏輯的 `*_S00_AXI.v` 樣板。
6. 將該 `.v` 檔案複製到專案的 `rtl/` 目錄下即可直接套用！

### 2.2 打包自訂 IP 並加入 IP 庫 (IP Repository)
如果希望自訂 Verilog 模組能在 Block Design 畫布中像官方 IP 一樣搜尋使用：
1. 在修改好的 IP 專案中開啟 **Package IP** 視窗。
2. 依序檢查 **Ports and Interfaces**, **Addressing and Memory**, **GUI Layout**。
3. 點擊 **Review and Package** ➔ 點擊 **Re-Package IP**。
4. 回到主專案，點擊 **Settings** ➔ **IP** ➔ **Repository** ➔ 點擊 `+` 號加入存放 IP 的 `ip_repo/` 資料夾。

---

## 階段 3：Block Design 頂層系統整合 (IP Integrator)

### 3.1 建立與配置系統框圖
1. 左側 **Flow Navigator** ➔ 點擊 **Create Block Design**（命名為 `design_1`）。
2. **加入官方 IP**：在畫布點擊 `+` (Add IP)，搜尋並加入 `DMA/Bridge Subsystem for PCI Express` (XDMA)。
3. **加入自訂 RTL 模組**：在畫布空白處右鍵 ➔ **Add Module...** ➔ 選取 `gpu_top`。
4. **雙擊 XDMA 配置**：
   * **Basic**：Mode 設為 `DMA`，Lane Width 設為 `X2` (PCIe Gen2 x2)，Interface 設為 `AXI Stream`。
   * **PCIe BARs**：勾選 **PCIe to AXI Lite Master Interface**，BAR0 Size 設為 `64 KB`。
   * **PCIe Misc**：勾選 **MSI 64-bit**，User Interrupts 設為 `1`。

### 3.2 訊號連線與外部引腳 (Make External)
1. **AXI 控制線**：`xdma_0/M_AXI_LITE` ──> `gpu_top/s_axi_ctrl`
2. **AXI-Stream 資料線**：
   * 下行 H2C：`xdma_0/M_AXIS_H2C_0` ──> `gpu_top/s_axis_dma`
   * 上行 C2H：`gpu_top/m_axis_dma` ──> `xdma_0/S_AXIS_C2H_0`
3. **MSI 中斷線**：`gpu_top/usr_irq_req` ──> `xdma_0/usr_irq_req[0]`
4. **外部物理腳位 (Make External)**：在 `xdma_0` 的 `sys_clk`、`sys_rst_n` 與 `pcie_mgt` 上點右鍵 ➔ 選擇 **Make External**。

### 3.3 自動 DRC 檢查與 Address Editor
1. **自動 DRC 驗證**：按下快捷鍵 **`F6`** (Validate Design)，Vivado 會自動檢查 Bus 寬度、時脈域 (Clock Domain) 與未連接的引腳。
2. **位址映射 (Address Editor)**：切換至 **Address Editor** 分頁，將 `gpu_top` 的 `s_axi_ctrl` 映射至位址 `0x4000_0000` (64KB)。
3. **產生頂層 Wrapper**：在 Sources 視窗中對 `design_1.bd` 右鍵 ➔ **Create HDL Wrapper** ➔ 選擇 *Let Vivado manage wrapper*。

---

## 階段 4：電路結構分析 (Schematic & Netlist 檢視)

在綜合前或綜合後，工程師需要檢查 RTL 模組內部的實體連線與邏輯閘展開情形：

### 4.1 開啟 RTL 原理圖 (Schematic)
1. 左側 **Flow Navigator** ➔ **RTL Analysis** ➔ 點擊 **Open Elaborated Design**。
2. 展開後直接點擊內部的 **`Schematic`** 按鈕（帶著邏輯閘圖示）。
3. 中央主視窗會立即繪製出頂層層級的電路原理圖。

### 4.2 顯示樹狀階層 Netlist 視窗
若找不到左側的模組階層樹：
1. 點擊 Vivado 頂部主選單 **Window** ➔ 勾選 **Netlist**（或 **Hierarchy**）。
2. 左側會彈出 **Netlist** 面板，展示 `gpu_top` 及其內部的 `u_regs` 與 `u_compute_core` 樹狀結構。

### 4.3 展開內部子模組電路
* 在 Schematic 或 Netlist 視窗中選中任何子模組（如 `gpu_top`），按下快捷鍵 **`F4`**（或右鍵 ➔ **Schematic**），即可深入查看該模組內部的邏輯閘與暫存器連線！

---

## 階段 5：RTL 功能模擬 (Behavioral Simulation)

在燒錄前，必須撰寫 Testbench 驗證波形與 AXI 握手時序：

### 5.1 加入 Simulation Testbench 檔案
1. **Add Sources** ➔ 選擇 **Add or create simulation sources** ➔ 點擊 **Next**。
2. 選取測試檔（如 `tb_gpu_top.v`）並匯入專案。

### 5.2 執行行為模擬 (Behavioral Simulation)
1. 左側 **Flow Navigator** ➔ **Simulation** ➔ 點擊 **Run Simulation** ➔ **Run Behavioral Simulation**。
2. Vivado 會編譯並開啟波形視窗 (**Waveform Viewer**)。

### 5.3 波形除錯常用操作
* **新增觀測訊號**：在 Scope 面板選中子模組 ➔ 將訊號拖拽至 Wave 面板（或右鍵 **Add to Wave Window**）。
* **重新運行模擬**：
  * 按下快捷鍵 **`F5`** (Restart) 重置時間。
  * 點擊工具列 **Run for 10us** 或 **Run All**。
* **基數切換**：在波形訊號上點右鍵 ➔ **Radix** ➔ 切換為 `Hexadecimal` 或 `Unsigned Decimal`。

---

## 階段 6：腳位約束與 Bitstream 綜合編譯

### 6.1 配置腳位與時脈約束 (.xdc)
在 `constrs/pcie.xdc` 中定義物理 Pin 腳與時脈週期：
```xdc
# PCIe 100MHz 參考時脈 (頂層埠口名稱 sys_clk)
set_property PACKAGE_PIN F10 [get_ports sys_clk]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]

# PCIe 系統重置腳位 (PERST#)
set_property PACKAGE_PIN T18 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]
```

### 6.2 處理編譯報錯與 Reset Runs
若修改代碼後 Synthesis 出現舊的邏輯殘留或編譯錯誤：
1. 切換至下方的 **Design Runs** 視窗。
2. 右鍵點擊 `synth_1` 或 `impl_1` ➔ 選擇 **Reset Run**。
3. 點擊 Flow Navigator 的 **Generate Bitstream**，Vivado 會自動依序執行 Synthesis ➔ Implementation ➔ Bitstream Generation！

---

## 階段 7：硬體下載與 Flash 固化燒錄 (Hardware Manager)

### 7.1 JTAG 臨時 Bitstream 下載 (Program Device)
1. 用 USB-JTAG 下載器連接 ALINX AX7A200B 開發板並開啟電源。
2. 左側 **Flow Navigator** ➔ **PROGRAM AND DEBUG** ➔ 點擊 **Open Hardware Manager**。
3. 點擊上方綠色 Banner 的 **Open Target** ➔ 選擇 **Auto Connect**。
4. 識別出晶片 `xc7a200t_0` 後，在晶片上點右鍵 ➔ **Program Device**。
5. 選取產生的 `.bit` 檔（位於 `fpga-gpu.runs/impl_1/design_1_wrapper.bit`）➔ 點擊 **Program**。

### 7.2 固化燒錄至 SPI Flash (斷電不遺失)
若要讓 FPGA 開機自動載入程式：
1. **產生 Flash 燒錄檔 (.mcs)**：
   * 頂部選單 **Tools** ➔ **Generate Memory Configuration File...**。
   * Format 選 `MCS`，Memory Part 選擇開發板的 Flash 型號（如 `w25q128-spi-x1_x2_x4`）。
   * 指定輸入 `.bit` 檔案路徑與輸出的 `.mcs` 檔案路徑 ➔ 點擊 **OK**。
2. **新增 Flash 記憶體裝置**：
   * 在 Hardware Manager 視窗中對 `xc7a200t_0` 右鍵 ➔ 選擇 **Add Configuration Memory Device**。
   * 搜尋並選擇開發板上的 SPI Flash 晶片型號。
3. **燒錄 .mcs 檔**：
   * 建立完成後，右鍵 Flash 裝置 ➔ **Program Configuration Memory Device...**。
   * 選取剛產生的 `.mcs` 檔案與 `.prm` 檔案 ➔ 點擊 **OK** 開始固化燒錄。

---

## 階段 8：業界 Git 版控與 Tcl 自動化工作流

大型晶片公司與業界團隊不會把龐大的 Vivado 專案（數 GB 的 `.runs`, `.cache`, `.hw` 目錄）提交到 Git，而是**使用純 Tcl 腳本重構專案**。

### 8.1 導出 Block Design 的 Tcl 重建腳本
在 Vivado 下方的 **Tcl Console** 執行以下指令：
```tcl
write_bd_tcl -force build_bd.tcl
```
這個指令會生成 `build_bd.tcl`。在任何全新的 Vivado 專案中，只要執行 `source build_bd.tcl`，就能在 3 秒內自動重建出 100% 一模一樣的 Block Design 畫布與 IP 配置！

### 8.2 導出全專案一鍵重建 Tcl 腳本
在 Tcl Console 執行：
```tcl
write_project_tcl -force recreate_project.tcl
```
這會生成全新的專案重建腳本。

### 8.3 業界推薦的 `.gitignore` 配置
FPGA 專案的 Git 倉庫**只需要追蹤以下檔案**：
1. `rtl/*.v` (Verilog 核心原始碼)
2. `constrs/*.xdc` (腳位約束檔)
3. `build_bd.tcl` (Block Design 腳本)
4. `recreate_project.tcl` (專案檔腳本)

**必須被忽略 (.gitignore) 的 Vivado 暫存目錄**：
```gitignore
*.log
*.jou
*.pb
*.jou
.Xil/
*.runs/
*.cache/
*.hw/
*.ip_user_files/
*.gen/
```

### Tcl commands
 
```bash
# use pwd and cd to comfirm path before executing commands
report_utilization -hierarchical -format xml -file ./utilization.xml
report_timing -delay_type max -max_paths 50 -sort_by group -nworst 2 -file ./timing.txt

```