# signer rehearsal 85dbc51

`script/dev/rehearse-signer.sh` on worktree HEAD 85dbc51, 2026-10-18, chain id 1 anvil fork (port 8618) at block 26217383, throwaway keystore signer carrying the EIP 7702 delegation code.

- phase 1, full run through the keystore with `--slow`: ok in 219 s, postflight passed, record written (deployBlock 26217387, coinLive true).
- phase 2, wrapper killed after 3 transactions landed: saved 11 transactions, 2 receipts. `RESUME=replay` sent the rest in 6 s. Resumed record equals the full run record (deployBlock 26217387 vs 26217387), transactions after resume 11, receipts 11.
- phase 3, one extra signer transaction after the kill: `RESUME=replay` refused: "the signer nonce 5 is past saved transaction 3 (nonce 4), which has no landed hash in broadcast/Deploy.s.sol/1/run-latest.json." Result: refused.
- cleanup: keystore, password file and anvil removed on exit; deployments/ untouched.
