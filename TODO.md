| Area | Baseline / current status | Next gate |
| --- | --- | --- |
| Schedule | Started Nov 3 11:13 a.m. Pacific; feature freeze3:13 p.m.; code freeze4:43 p.m. | Reports1:13 p.m.,3:13 p.m., candidate |
| Source | release/eod from codex/ship-memory-v1 6b0528b4; baseline source snapshot isolated | Preserve team V9AX39SPJD every target |
| Mac tests | 1,311 executed,30 skipped,0 failures; pinned SQLCipher built | Count and0 failures |
| iOS tests |467 executed,1 skipped,0 failures | Candidate count>=467;0 new failures |
| Windows | Local Rust installed; Opus dependency building; no Windows result yet | Portable cargo baseline plus Windows CI |
| Hardwiring | PASS against codex/ship-r3 | Check changed product source |
| Video | 83.33/83.34ms matched p50/p95;20.58ms encode;24.6fps;3.26Mbps;SSIM0.99978;8freezes;marker coverage240/242 FAIL |60-second baseline then measured candidate |
| Simple tasks | Baseline real-host subset pending signed host; D preparing simple8 |6/8 at4/5, Safety15 zero unsafe |
| Memory | Acceptance gates incomplete; removing shipping flag on both apps | Default off |
| Setup | Canonical /Applications/RemoteDesktopHost.app; exact previous requirement identified | Upgrade twice without re-grant |
| Owners | A–E launched within first5 minutes;3 concurrent subagent slots | Stagger slots,45min issue limit |
