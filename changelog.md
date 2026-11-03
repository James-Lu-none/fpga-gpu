# Changelog

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
