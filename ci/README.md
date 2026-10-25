# Local CI artifacts

GitHub artifact upload/download steps are temporarily commented out because of storage quota errors.

- Root: `/home/github-runner/ci-artifacts/<owner>/<repo>/<run-id>/<attempt>/`.
- `software/`: build/test evidence; `vivado/`: checkpoint, reports, or generated bitstream.
- Each save uses an immutable run-attempt directory; the path appears in the job summary.
- Manually trigger **Generate FPGA Bitstream** with a successful CI run ID. It validates the GitHub run, restores that run's latest attempt from local storage, then checks source SHA, Vivado version and checkpoint checksum.
- All jobs must use the same physical runner. These files survive checkout cleanup, but are not backed up to GitHub.
- No automatic expiration is configured. Monitor disk usage and manually remove old run directories only after their checkpoints are no longer needed.
- Use SSH/SCP to retrieve outputs. Uncomment the original artifact steps to restore GitHub storage, and disable the corresponding local save/restore steps.
