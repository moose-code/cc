# local end to end through the web app at ecf51f3

date 2026-10-13. `PORT=8546 PHASE=post script/dev/local.sh` (an anvil fork of block 26158000 with the system deployed by script/deploy.sh, the seed with the mock balance token, the best guess redeem module, an eth/balance pool and every switch on, then the 22 scenario stages), then the web app (`npm --prefix web run dev:local`, reading deployments/31337.json) driven in the desktop app's browser pane as the local account a1.

| action in the UI | result on chain |
|---|---|
| sell credit #6956 for eth (approve and sell) | `CreditBought` at 0.0128 eth, the pot fell, the bid dropped and climbed back |
| sell credit #12413 for $balance | `CreditBought` at 181.94 $BALANCE, the balance pot fell by it |
| redeem statement 178 (at floor, redeemable) | `StatementRedeemed`, 27,089.17 $BALANCE received, the statement with the module |
| buy statement 180 at the gross price 1.5102 eth | `StatementSoldTo` 1.4754 engine price, 0.7377 to the buyback, `AnchorMoved` to 149.83 percent, the royalty owed 0.0368 |
| buyback | `Buyback` 0.4995 eth spent, 5.5M CC burned (16.7M, 1.67 percent of supply in all), keeper paid 0.0005 |
| claim royalty | `RoyaltyClaimed` 0.0383 eth to the recipient |
| book fees | `FeesAdded` 0.0307 eth |

the home page's flywheel numbers, the stats bar and the feed updated after each action. the restyle and the chosen compose buttons stay disabled for a1 (it holds no CC, the 1 coin gate) and `compose` needs 67 more credits than the test accounts hold: both doors ran in the scenario stages (`format`, `fresh-compose`), not through the UI. a seed change that gives a1 one coin and a full page would let the UI drive them too.
