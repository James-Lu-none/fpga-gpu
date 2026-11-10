# Changelog

## 2026-11-10: Complete NZP Elimination & Direct Register-Based Branching (`BR R<rd>, target`)

### Outcome and Architectural Significance
- Fully eliminated implicit condition flags (`warp_nzp`) from the GPU hardware architecture, completing the migration to a modern register-based instruction set (similar to RISC-V `bnez` and modern SIMT GPUs).
- Hardware resource savings: Removed `reg [2:0] warp_nzp [0:MAX_WARPS-1][0:NUM_LANES-1]` from `pc.sv`, saving 768 Flip-Flops per Sub-Partition (SP), totaling **6,144 Flip-Flops across the GPU (8 SPs)**.
- Compiler efficiency: Eliminated the redundant `CMP condReg, R0` instruction before every conditional branch, reducing code size by 1 instruction and latency by 1 issue cycle per branch.
- Passed 100% of all unit tests and OpenCL workloads in Verilator simulation.

### Hardware RTL Changes
1. **Vector Register File Read Muxing ([`vector_regfile.sv`](file:///home/user/workspace/fpga-gpu/fpga-gpu-hardware/rtl/sm/sp/vector_regfile.sv#L25-L35))**:
   - For `BR` (`opcode == 8'hC0`), routed `decode.rd` to the `rs1` BRAM address read port (`eff_rs1 = (decode.opcode == 8'hC0) ? decode.rd : decode.rs1`).
   - The tested register's per-lane contents are read into `op.rs1_data` synchronously with instruction issue.
2. **Branch Condition Evaluator ([`pc.sv`](file:///home/user/workspace/fpga-gpu/fpga-gpu-hardware/rtl/sm/sp/pc.sv))**:
   - Pipelined `op.rs1_data` through `op_rs1_data_q` and `ex1_rs1_data` to match the 2-cycle execution pipeline.
   - Replaced NZP matching with direct register inspection:
     - `ex1_rd == 5'd0` (`R0`): Unconditional branch (`lane_cond = 1'b1`).
     - `ex1_rd != 5'd0` (`R1..R31`): Conditional branch (`lane_cond = (ex1_rs1_data[lane] != 32'd0)`).
   - Removed `warp_nzp` register storage and reset logic.
3. **Module Interface Cleanup**:
   - Removed `alu_updates_nzp`, `lane_nzp`, and `next_nzp` wires and ports across [`pc.sv`](file:///home/user/workspace/fpga-gpu/fpga-gpu-hardware/rtl/sm/sp/pc.sv), [`sp_ctrl.sv`](file:///home/user/workspace/fpga-gpu/fpga-gpu-hardware/rtl/sm/sp/sp_ctrl.sv), [`sp_dpath.sv`](file:///home/user/workspace/fpga-gpu/fpga-gpu-hardware/rtl/sm/sp/sp_dpath.sv), and [`sp_top.sv`](file:///home/user/workspace/fpga-gpu/fpga-gpu-hardware/rtl/sm/sp/sp_top.sv).

### Compiler & Toolchain Changes
1. **ISA Binary Format ([`FpgaGpu.h`](file:///home/user/workspace/fpga-gpu/fpga-gpu-compiler/include/FpgaGpu.h#L133-L137))**:
   - `Opcode::BR` machine word bits `[23:19]` now encode the predicate register `rd` (`0` for unconditional, `1..31` for conditional). Immediate jump offset occupies bits `[18:0]`.
2. **Assembler & Disassembler ([`FpgaGpuAssembler.cpp`](file:///home/user/workspace/fpga-gpu/fpga-gpu-compiler/src/FpgaGpuAssembler.cpp))**:
   - Assembly syntax:
     - Unconditional: `BR <label/offset>` (sets `rd = 0`).
     - Conditional: `BR R<rd>, <label/offset>` (branches if `VRF[rd] != 0`).
     - Backward compatibility: Legacy condition code mnemonics (e.g. `BR NZP, ...`, `BR ALWAYS, ...`) are parsed as `rd = 0`.
   - Disassembler prints `BR <offset>` when `rd == 0` and `BR R<rd>, <offset>` when `rd != 0`.
3. **Instruction Selection Simplification ([`FpgaGpuISel.cpp`](file:///home/user/workspace/fpga-gpu/fpga-gpu-compiler/src/FpgaGpuISel.cpp#L382-L415))**:
   - `selectBranch` now directly emits:
     - `BR condReg, TrueTarget`
     - `BR R0, FalseTarget`
   - Completely eliminated synthetic `CMP condReg, R0` emission.

### Verification & Regression
- `ctest` passed 100% on compiler tests.
- `make lint` passed with 0 warnings.
- `make clean check` passed 100% on all hardware unit tests and OpenCL kernels:
  - `tb_mul32`: PASS
  - `vector_regfile_tb`: PASS
  - `cache_store_tb`: PASS
  - `lsu_reset_tb`: PASS
  - `test_opencl_minimal`: PASS
  - `test_opencl_minimal_branch`: PASS
  - `test_opencl_matmul`: PASS
  - `test_opencl_vector_add`: PASS
  - `test_opencl_matmul_occupancy`: PASS
  - `test_opencl_branch_divergence`: PASS

---

## 2026-11-10: Compiler Compound Branch Predicate Lowering Fix (Resolved Occupancy Stress Test Failure)

### Outcome and Evidence
- Resolved the 64-block failure in `test_opencl_matmul_occupancy` (`Case 6/6: Grid=(8,16), Block=(2,1)`), which previously reported 2 mismatches:
  `FAIL row=1 col=2 actual=25 expected=58`
  `FAIL row=1 col=3 actual=16 expected=72`
- All unit tests and all six OpenCL workloads (`test_opencl_minimal`, `test_opencl_minimal_branch`, `test_opencl_matmul`, `test_opencl_vector_add`, `test_opencl_matmul_occupancy`, `test_opencl_branch_divergence`) now pass 100% (0 warnings, 0 mismatches) on both baseline hardware configuration (`NUM_LANES=8, NUM_SUB_PARTITIONS=2`) and expanded scale (`NUM_LANES=32, NUM_SUB_PARTITIONS=4`).

### Edge Case & Root Cause Analysis
1. **Frontend Optimization**:
   In `test_opencl_matmul_occupancy.c`, the kernel bounds check is written as `if (row < N && col < N)`.
   Clang with `-O2` simplifies the short-circuit condition into a single boolean `select` instruction:
   ```llvm
   %12 = icmp slt i32 %row, %N
   %13 = icmp slt i32 %col, %N
   %14 = select i1 %12, i1 %13, i1 false
   br i1 %14, label %bb.1, label %bb.0.sync
   ```
2. **Compiler ISel Fallback Bug**:
   The compiler backend (`FpgaGpuISel.cpp:selectBranch`) previously only recognized conditions directly matching `dyn_cast<llvm::ICmpInst>(condVal)`.
   When presented with `SelectInst` (`%14`), it failed to match and silently defaulted to `branchCond = BranchCond::NE` (emitting `BR NP`, i.e., non-zero) **without emitting any comparison for `%14`**.
3. **Stale NZP Condition Execution**:
   Because no comparison was emitted, `BR NP` evaluated the stale condition flags from the preceding instruction in `bb.0`, which happened to be `%13` (`CMP col, N`).
   For an out-of-bounds thread with `col > N` (e.g., `col = 6, N = 4`):
   - `col - N = 6 - 4 = +2` (Positive, `P`).
   - The condition `NP` (Negative or Positive, i.e. `!= 0`) matched `+2`!
   - As a result, out-of-bounds threads incorrectly took the branch into `bb.1` and executed the matrix multiply.
4. **Aliasing and Memory Corruption**:
   In Case 6 (`Grid=(8, 16)`, 64 blocks of 2 threads), Block `(bid_x=3, bid_y=0)` has `row = 0`, `col = 6` (lane 0), and `col = 7` (lane 1).
   These out-of-bounds threads calculated:
   - Lane 0: $A[0] \times B[:, 6] = 1\times 3 + 2\times 2 + 3\times 6 + 4\times 0 = \mathbf{25}$
   - Lane 1: $A[0] \times B[:, 7] = 1\times 4 + 2\times 3 + 3\times 2 + 4\times 0 = \mathbf{16}$
   The store instruction targeted address $C[\text{row} \times N + \text{col}] = C[0 \times 4 + 6] = C[6]$ and $C[7]$.
   In a flattened $4 \times 4$ matrix:
   - $C[6]$ aliases to `row = 1, col = 2` (expected 58).
   - $C[7]$ aliases to `row = 1, col = 3` (expected 72).
   Thus, the valid results computed by Block `(bid_x=1, bid_y=1)` were overwritten with 25 and 16.
5. **Why Concurrency Triggered the Bug**:
   With 2 sub-partitions per SM, Block `(3, 0)` completed before Block `(1, 1)`, so Block `(1, 1)` accidentally overwrote the corrupted entries with correct values before verification.
   When `NUM_SUB_PARTITIONS` was expanded from 2 to 4, the doubled scheduling capacity allowed Block `(1, 1)` to finish earlier (cycle 5812) on SP2 and Block `(3, 0)` to finish later (cycle 5813) on SP1, exposing the latent corruption.

### Resolution & Generalization to $N$-ary Compound Conditions
- In `FpgaGpuISel.cpp`, generalized the conjunction/disjunction lowering logic from a 2-operand check (`c1, c2`) to full recursive expression flattening:
  - `collectConjuncts`: Recursively traverses arbitrary nested AST trees of `SelectInst` (`select cond, trueVal, 0`) and `BinaryOperator(And)` to extract all leaf `ICmpInst` conditions $[C_0, C_1, \dots, C_{N-1}]$.
  - `collectDisjuncts`: Recursively traverses nested AST trees of `SelectInst` (`select cond, 1, falseVal`) and `BinaryOperator(Or)` to extract all leaf `ICmpInst` conditions for disjunctions.
  - Lowering for Conjunctions ($N$ conditions, e.g. `if (a && b && c ...)`):
    - For $i = 0 \dots N-2$: emits `CMP C_i; BR invCond(C_i), FalseTarget` (short-circuit exit on any failure).
    - For $C_{N-1}$: emits `CMP C_{N-1}; BR cond(C_{N-1}), TrueTarget; BR ALWAYS, FalseTarget`.
  - Lowering for Disjunctions ($N$ conditions, e.g. `if (a || b || c ...)`):
    - For $i = 0 \dots N-2$: emits `CMP C_i; BR cond(C_i), TrueTarget` (short-circuit taken on any success).
    - For $C_{N-1}$: emits `CMP C_{N-1}; BR cond(C_{N-1}), TrueTarget; BR ALWAYS, FalseTarget`.
  - `feedsOnlyConditionalBranch`: Recursively verifies whether an `ICmpInst` only feeds conditional branches through arbitrary levels of `Select`/`And`/`Or`, ensuring `CMP` instructions are exclusively emitted immediately adjacent to their branch operations without premature dead CMP instructions or pipeline NZP clobbering.

## 2026-11-10: Hardware & Compiler Architectural Upgrade (Route A: Vector Bitwise Logic & SETCC)

### Motivation & Architectural Significance
- In early iterations, the GPU lacked vector bitwise instructions and general-purpose condition evaluation into registers, forcing the compiler to lower compound predicates (`a && b && c`) into fragile, multi-stage short-circuit branch cascades with multiple SIMT divergence pushes.
- Route A upgrades the GPU ISA and execution pipeline to support register-based boolean and predicate evaluation, matching modern GPU standards (e.g. RISC-V / NVIDIA / AMD).

### Key Changes
1. **Hardware ISA & Execution Pipeline (`fpga-gpu-hardware`)**:
   - Added 4 R-type instructions:
     - `AND` (`0x05`): `VRF[rd] = VRF[rs1] & VRF[rs2]`
     - `OR`  (`0x06`): `VRF[rd] = VRF[rs1] | VRF[rs2]`
     - `XOR` (`0x07`): `VRF[rd] = VRF[rs1] ^ VRF[rs2]`
     - `SETCC` (`0x08`): `VRF[rd] = (VRF[rs1] cond VRF[rs2]) ? 1 : 0`, supporting all 6 relational operators (`LT`, `LE`, `GT`, `GE`, `EQ`, `NE`) via instruction bits `[8:6]`.
   - Updated `alu_int32.sv`, `sp_ctrl.sv`, and `sp_dpath.sv`. Logic results are registered in `ex1_logic` and forwarded through EX2, updating VRF and lane-level NZP flags.
2. **Assembler & Toolchain (`fpga-gpu-compiler`)**:
   - Added support in `FpgaGpu.h`, `FpgaGpuAssembler.cpp`, and `FpgaGpuEmitter.cpp` for `AND`, `OR`, `XOR`, `SETCC`, and aliases (`SLT`, `SEQ`, `SNE`, `SGT`, `SGE`, `SLE`).
3. **Compiler Instruction Selection Simplification (`FpgaGpuISel.cpp`)**:
   - Removed ~150 lines of complex AST tree-walking and synthetic branch cascade logic (`feedsOnlyConditionalBranch`, `collectConjuncts`, `collectDisjuncts`, `getInverseBranchCond`).
   - `selectCmp` emits `SETCC rd, rs1, rs2, cond` directly into virtual registers.
   - `selectBinaryOp` naturally emits `AND`, `OR`, `XOR`.
   - `selectBranch` evaluates `condReg != 0` via `CMP condReg, R0` and a single `BR NE` instruction.
   - Compound predicates (`if (a && b && c ...)`) now evaluate in register dataflow, resulting in exactly **one** branch and at most **one** SIMT stack divergence event.

### Verification & Regression
- `make clean check` in Verilator passed 100%:
  - All unit tests (`tb_mul32`, `vector_regfile_tb`, `cache_store_tb`, `lsu_reset_tb`) passed.
  - All 6 OpenCL end-to-end tests passed (including 64-block `test_opencl_matmul_occupancy` and `test_opencl_branch_divergence`).

## 2026-11-03: Separate PCIe readiness and bounded recovery

- A rebuilt image completed Flash verification and reached DONE=HIGH, but the Host could not enumerate its PCIe endpoint. The programming/rescan code matched the earlier passing version; the cause of this link-recovery failure remains unconfirmed.
- Move post-programming rescan into `pcie-ready`, between loading and hardware tests. Check live PCI identity, BAR assignments and driver ownership instead of relying only on sysfs device presence.
- On readiness timeout or SSH loss, preserve available evidence, power-cycle B once and retry. SRAM mode reloads the same verified CI binary after power-on; Flash mode uses the programmed Flash image. No repeated recovery loop or upstream-bus reset is attempted.
- Keep both the failed direct attempt and fallback result in local artifacts and the Actions summary. Hardware tests require PCIe readiness; final shutdown still runs after failure.

## 2026-11-03: GPU bring-up fixes and diagnostic cleanup

### Outcome and evidence

- All hardware tests passed on AX7A200B after the VRF and DMA fixes. They also passed after removing the host power cycle between Flash programming and testing.
- The successful reference is top repo `b25a131`, hardware `3d8d9ac`, driver `932a825`, compiler `e0eba5f`, firmware `4e1e0c8`.
- These exact heads are preserved in every repo as `temp/hardware-debug-20261103`. Clean fixes are rebuilt separately on `fix/gpu-memory-path`.
- The cleaned branch removes diagnostic circuitry and changes synthesis inputs. The earlier hardware pass is evidence for the fixes, not a substitute for rebuilding and testing this branch before merging.

### Root causes

1. VRF read-port synthesis failure.
   - Host DMA and fixed L2, L1 and LSU writes all passed, but GPU stores targeted address zero. This narrowed the failure to operand generation rather than DDR or PCIe transport.
   - The direct VRF probe returned zero on rs1 while rs2 correctly read the same register. The failure affected all eight warps and reproduced in the synthesized netlist, even though RTL simulation passed.
   - The original code updated duplicated wide RAM arrays with lane slices inside one procedural loop. Independent 32-bit, full-word synchronous RAM instances for each lane/read port restored correct synthesized rs1 reads.
   - The hardware probe then passed all 1,016 snapshots. The exact Vivado optimization defect was not established; the confirmed issue is an RTL-versus-synthesized behavior mismatch resolved by the RAM template change.
   - Splitting asynchronous valid reset from clock-only metadata removed ambiguous-reset warnings, but that change alone did not fix rs1. Preserve both valid alignment and the two-cycle operand latency.

2. DMA scatter/gather range corruption.
   - The driver ignored the Host pointer's offset within its first page, pinned pages using only the byte count, and described every page as a full-page transfer.
   - The branch-divergence test used small, unaligned stack buffers, unlike the page-aligned buffers in passing tests. Uploads read the wrong bytes and downloads could overwrite memory beyond the requested range. This made a transport bug look like a branch or arithmetic bug.
   - Calculate page coverage from offset plus length, preserve the first-page offset, limit every segment to the remaining byte count, reject address wraparound, and unwind partial page-pinning failures.
   - Keep the original small branch buffers. Short/cross-page DMA guard tests and pre-dispatch input/sentinel readback prevent an alignment workaround from hiding a recurrence. The final hardware suite passed after this fix.

### Additional correctness fixes retained

- Route the combined Host/GPU completion IRQ to PicoRV32. Using only the Host IRQ omitted GPU-completion delivery and could leave firmware waiting after dispatch.
- Treat a cache store response as an acknowledgement, not a read fill. Its payload is undefined; invalidate the written line and refill on the next load. Retain the poisoned-response and partial-store regression plus the corrected VRAM model.
- Materialize constant operands before normal and inline-assembly stores in the compiler. Otherwise a constant could refer to an uninitialized virtual register.
- Load firmware through the enumerated PCIe `resource0`, and fail on reset/IRQ verification errors instead of reporting success.
- Scope the Flash part lookup to the detected FPGA and deduplicate repeated catalog entries. Preserve the existing local hw_server connection and disabled cs_server setting.
- These were independently identified code defects. The debugging sequence did not separately measure each one's contribution to every original failure.

### CI and code cleanup inventory

1. Remove from the normal workflow.
   - The `cold-boot` job, boot-ID check and power-cycle helper. Program/verify Flash, boot the FPGA through JTAG, rescan PCIe, then run hardware tests without rebooting B.
   - The `hardware_mode` input/environment, diagnostic bitstream selection and six fixed-pattern memory tests.
   - Direct-ISA and four minimal-writeback bring-up stages before the normal workload suite.
   - The BAR0 debug command/reader and its Python reader tests; no system-CSR/GPC debug alias is introduced.
   - The synthesis warning scan and probe-specific XSim export/port checks. They depended on temporary diagnostic hierarchy; the netlist failure evidence remains in the temp branch and runner artifacts.

2. Restore production hardware and firmware.
   - Remove `l2_memory_test.sv`, `vrf_probe.sv`, their CSR maps, GPC replacement mux/CPU hold-reset and diagnostic project define.
   - Remove VRF raw-data/select output ports, open debug connections and probe-only DONT_TOUCH attributes.
   - Revert added AXI first-transaction snapshots, GPC diagnostic registers and extra firmware counter/snapshot printing to the selected baseline.
   - Preserve the actual VRF RAM/reset fixes, IRQ wiring and cache acknowledgement semantics.

3. Keep focused regressions and ordinary hardware CI.
   - Keep `vector_regfile_tb.sv`, `cache_store_tb.sv`, the existing LSU reset test and OpenCL RTL regressions. They test production behavior without adding diagnostic hardware.
   - Keep exact-range DMA payload/guard tests and branch pre-dispatch readback. Restore exploratory ISA/L2/VRF Host tools and modified minimal kernels to the baseline.
   - Keep native compiler/firmware/driver builds on B, module load/unload, DMA and the five standard OpenCL workloads, UART/dmesg/results collection and unconditional final shutdown.
   - Keep artifact checksums, pinned source deployment, runner-local evidence and only the final binary upload. Hardware scripts stay in their submodule; B operations stay in `dut.py` and `hardware-test.sh`.

### Review bases and commit order

- Top repo master: `7f3368d` (move all machine B operation to dut.py).
- Compiler master: `2b1b2e9` (add llvm ir emit option).
- Driver master: `0070674` (add debug output).
- Hardware master: `4d920c7` (set labtools.enable_cs_server false).
- Firmware master: `205a518`, as recorded by top repo `7f3368d`.
- All bases include the named commit. Remote master updates use explicit expected-SHA leases after publishing the backup branches.
- Review hardware IRQ, cache/model regression, valid-reset separation, independent RAM/regression and Flash lookup commits; then compiler constant stores, driver DMA/regressions and firmware BAR loading.
- Top-level commits pin those fixes separately, add the cleaned hardware-test job, and document this investigation. Merge submodule fixes before the top-level pointer updates. No fix branch is merged automatically.

### Clean-branch validation

- Passed: compiler build and CTest, VRF streaming/reset regression (1,024 operands), poisoned cache-store response regression, LSU reset regression, and all six OpenCL RTL simulations.
- Passed: strict-warning builds of the DMA/branch tests, firmware build, kernel module build against local 6.17 headers, CI Python/shell syntax and workflow dependency checks.
- Pending: Vivado implementation/timing and a fresh AX7A200B run of the cleaned branch. Do not treat the earlier diagnostic-head hardware result as validation of a newly synthesized image.
