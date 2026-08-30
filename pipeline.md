# FPGA-GPU Execution Flow & Data Formats (Detailed Module Mapping)

這份文件詳細說明了我們全新架構的 GPU 從「接收任務」到「完成運算」的完整端到端 (End-to-End) 執行流程，並精確標示每個操作對應的 **硬體模組** 與 **原始碼檔案**。

---
## 1. 任務發布 (Host PC -> RISC-V Firmware)
**發生位置**：PCIe XDMA IP -> BRAM Controller -> Mailbox RAM  
**相關檔案**：`rtl/gpu/gpu_top.sv`、`fpga-gpu-firmware/main.c`

- **動作細節**：
  - Host PC (Linux/Windows Driver) 透過 PCIe 寫入資料。XDMA IP 會將 PCIe 封包轉換成 AXI4-Lite 請求。
  - AXI4-Lite 請求進入 `gpu_top.sv`，被路由到 Mailbox BRAM (Port B)。
  - 寫入 Mailbox 的動作會觸發 `doorbell_irq_reg` 硬體訊號 (`rtl/gpu/gpu_top.sv`)，這個訊號直接連到 PicoRV32 (Command Processor) 的中斷腳位。
  - Firmware (`main.c`) 從 `wfi` 狀態甦醒，進入 `irq_handler()`，讀取 64-Byte 的 `cuda_task_descriptor_t` 結構體。

---

## 2. 硬體配置與啟動 (RISC-V -> GPU Processing Cluster)
**發生位置**：Firmware -> AXI-Lite Decoder  
**相關檔案**：`rtl/gpc/processing_cluster.sv`

- **動作細節**：
  - Firmware 將 Descriptor 內的值，寫入 GPC 的 MMIO 暫存器 (Base: `0x1000_0000`)。
  - 在 `processing_cluster.sv` 的 AXI-Lite Register Decoder 中，這些寫入被解碼並儲存：
    - `0x0C` -> `grid_dim_x`
    - `0x10` -> `grid_dim_y`
    - `0x20` -> `src_addr`
    - `0x24` -> `dst_addr`
  - 最後 Firmware 寫入 `0x00` (DOORBELL)，這會拉起 `hw_trigger` 脈衝。

---

## 3. 動態負載平衡 (GPC TBS -> SM Array)
**發生位置**：GigaThread Engine (TBS)  
**相關檔案**：`rtl/gpc/thread_block_scheduler.sv`、`rtl/sm/block_receiver.sv`

- **動作細節**：
  - `hw_trigger` 啟動 TBS (`thread_block_scheduler.sv`)，進入 `STATE_ISSUE` 狀態。
  - TBS 根據 `grid_dim` 計算總共需要派發多少個 Thread Block。
  - TBS 讀取由 `SM0` 和 `SM1` 即時回報的 `sm_available_warp_slots`，比較後選出容量最大 (最閒) 的 SM。
  - TBS 將 `block_issue_valid` 拉高，並把 `block_idx_x`、`warps_per_block` 傳給選中的 SM。
  - 被選中的 SM 內部的 `block_receiver.sv` 接收該 Block，進入 `ST_ISSUE_WARP` 狀態，透過迴圈將 Block 拆成多個 Warps，呼叫 `alloc_valid` 塞進 `warp_context.sv` 的 Context RAM 中。

---

## 4. 運算執行 (SM Sub-Core Pipeline)
**發生位置**：SM Core (Warp Context -> Fetch/Decode -> ALU)  
**相關檔案**：`rtl/sm/warp_context.sv`、`rtl/sm/alu.sv`、`rtl/sm/pc.sv`

- **動作細節**：
  - `warp_context.sv` 負責排程 Warp，將 Ready 的 Warp 送入 `fetch_decode.sv`。
  - 提取的指令會進入 `vector_regfile.sv` 讀取暫存器，接著進入 `alu.sv` 執行。
  - **2-Cycle ALU Pipeline**: 為了打破 32-bit DSP 乘法器造成的 Timing Violation，ALU 採用兩級管線：
    - **EX1**: 執行算術運算 (Add/Sub/Mul)，結果存入內部管線暫存器。
    - **EX2**: 進行條件碼 (NZP) 評估與 Mux 選擇。
  - `pc.sv` 接收 NZP 結果，計算 Next PC 並處理 Branch Divergence (分支發散)，最後透過 `ctx_wb` 將結果寫回 `warp_context.sv`。

---

## 5. 記憶體存取 (LSU -> L1 Cache -> L2 Cache -> Global Memory)
**發生位置**：SM Load/Store Unit -> GPC L2 Cache -> DDR3  
**相關檔案**：`rtl/sm/lsu.sv`、`rtl/sm/l1_cache.sv`、`rtl/gpc/l2_cache.sv`

- **動作細節**：
  - 當遇到 Load/Store 指令時，`lsu.sv` 計算記憶體位址，向 SM 內部的 `l1_cache.sv` 發出請求。
  - **L1 Cache (4KB)**：Hit 時直接在 1 cycle 內回傳資料。Miss 時，向 GPC 層級的 `l2_cache.sv` 發送請求。
  - **L2 Cache (16KB)**：
    - `l2_cache.sv` 使用管線化仲裁 (`STATE_IDLE` 接收請求, `STATE_COMPARE` 查表比對) 來服務多個 SM。
    - 若 L2 Hit，從 BRAM 讀出資料回傳。
    - 若 L2 Miss，則透過 AXI4-Full (256-bit) 介面向外部 DDR3 控制器 (MIG) 發起 Burst 讀寫，完成後將資料填入 Cache 並回傳給 SM。

---

## 6. 任務完成與回報 (GPC -> RISC-V -> Host PC)
**發生位置**：Warp Context -> TBS -> Interrupt Handshake  
**相關檔案**：`rtl/sm/warp_context.sv`、`rtl/gpu/gpu_top.sv`

- **動作細節**：
  - 當 Warp 執行到 `EXIT` 指令，`warp_context.sv` 將狀態設為 `STATE_FREE`，使 `available_warp_slots` 增加。
  - TBS (`thread_block_scheduler.sv`) 在 `STATE_WAIT_DONE` 發現所有 Block 派發完畢且所有 SM 都滿載空閒 (Slots == 16)，就會拉起 `grid_done` 訊號。
  - `processing_cluster.sv` 將此訊號寫入 `grid_done_reg` (Bit 0 of `REG_INT_STATUS`)。
  - Firmware (`main.c`) 透過 `while (REG_INT_STATUS == 0)` 發現任務完成，將 Mailbox 的 `num_elements` 寫為 `0x2` (Done)。
  - Firmware 執行 `__builtin_trap()`，觸發 PicoRV32 的 `trap` 腳位。
  - `gpu_top.sv` 捕捉到 `trap`，將 PCIe 的 `usr_irq_req` 拉高。
  - Host PC XDMA Driver 收到中斷，透過 `usr_irq_ack` 完成交握，任務正式結束。
