# Case EXP1: Failed logons against `labuser`

| | |
|---|---|
| **Case ID** | EXP1 |
| **Status** | Analysis done, report written |
| **Analyst** | Lab owner |
| **Host** | `win11-soc` (Windows 11 Pro, build 26300), 10.10.10.101, isolated network `soc-lab` |
| **Date of activity** | 2026-10-27 |
| **Time zone** | Local time is CET (UTC+1). I give UTC where it matters. |
| **Type** | Lab simulation: I played the attacker myself, so I know what really happened |

---

## 1. Summary
I simulated someone guessing the password of a local account. Six wrong passwords for `labuser` were typed at the login screen within 9 seconds (11:28:47 to 11:28:56), and about three minutes later the correct one was used (11:32:06). In the logs this looks exactly like a password guess that eventually worked. Everything happened at the keyboard of the VM itself; nothing came over the network.

While checking the logs, I found one more failed logon for `labuser` at 11:37:26 that **I did not cause**. I traced it to a program (`msedgewebview2.exe`) running inside the `labuser` session I had left open. My conclusion: harmless (a benign true positive), but only with medium confidence, because I couldn't find out which app started that program.

## 2. Lab setup
- My PC runs Windows 10 Pro with VirtualBox 7.2.20 (using VT-x).
- Two VMs: `win11-soc` (the target, 10.10.10.101) and `ubuntu-soc` (10.10.10.100, not used in this case).
- Both sit on a private VirtualBox network, `soc-lab` (10.10.10.0/24). There's no gateway, so they can't reach the internet or my PC.
- Windows was set to log both successful and failed logons (`Logon` = Success and Failure).
- Account policy: lockout after 10 wrong passwords for 10 minutes. Minimum password length was **0**, which is worth fixing (see recommendations).

## 3. What I actually did
1. Created a normal local user, `labuser`.
2. At the lock screen, typed wrong passwords for `labuser`. I planned 5.
3. Logged in as `labuser` with the right password.
4. Went back to my `analyst` account with Switch user (not Sign out).

My own notes said I did this **between 11:28 and 11:33**.

## 4. Timeline from the logs
Source: `timeline.csv` / `exp1-logons.evtx`.

| Local time | UTC | Event | Account | Logon type | Sub status | Subject | Notes |
|---|---|---|---|---|---|---|---|
| 11:28:47 | 10:28:47 | 4625 | labuser | 2 | 0xC000006A | WIN11-SOC$ | Wrong password |
| 11:28:49 | 10:28:49 | 4625 | labuser | 2 | 0xC000006A | WIN11-SOC$ | Wrong password |
| 11:28:51 | 10:28:51 | 4625 | labuser | 2 | 0xC000006A | WIN11-SOC$ | Wrong password |
| 11:28:52 | 10:28:52 | 4625 | labuser | 2 | 0xC000006A | WIN11-SOC$ | Wrong password |
| 11:28:54 | 10:28:54 | 4625 | labuser | 2 | 0xC000006A | WIN11-SOC$ | Wrong password |
| 11:28:56 | 10:28:56 | 4625 | labuser | 2 | 0xC000006A | WIN11-SOC$ | Wrong password |
| 11:32:06 | 10:32:06 | 4624 | labuser | 2 | - | WIN11-SOC$ | **Success.** New Logon ID `0x3FB340` |
| 11:32:51 | 10:32:51 | 4624 ×2 | analyst | 2 | - | WIN11-SOC$ | Me logging back in (admin accounts get two: normal + elevated) |
| 11:37:25 | 10:37:25 | 4624 | SYSTEM | 5 | - | WIN11-SOC$ | A Windows service starting (`services.exe`). See 5.3. |
| 11:37:26 | 10:37:26 | 4625 | labuser | 2 | 0xC000006A | **labuser** (`0x3FB340`) | **Not me.** Caller `msedgewebview2.exe`. See 5.3. |

There's no logoff event (4647) for `labuser`, which fits what I did: I switched users, so the `labuser` session stayed open in the background.

## 5. What I found

### 5.1 The failed logons (11:28:47 to 11:28:56)
- Logon type 2, source address `127.0.0.1`, caller `svchost.exe`: all of this points to someone **at the keyboard**, not someone coming in over the network.
- Sub status `0xC000006A` means the username was right and the password was wrong. So whoever did this **knew a real account name** and was only guessing the password.
- The attempts were about 2 seconds apart. That's fast, but I was pressing Enter quickly, so I wouldn't call it automated based on timing alone.
- I planned 5 attempts, but the log shows **6**. I trust the log over my memory here; I probably hit Enter one extra time.
- After a few tries Windows made me wait ("delaying next attempt"). I never got close to the lockout limit of 10.

### 5.2 The successful logon (11:32:06)
- Same account, same logon type (2), same process (`svchost.exe`, PID `0x810`) as the failures.
- Several failures and then a success on the same account is the classic sign of a **password guess that worked**. If this were a real incident, I'd treat `labuser` as compromised.

### 5.3 The failed logon I didn't do (11:37:26)
This one didn't fit my story, so I dug into it.

- I was already logged in as `analyst` since 11:32:51, and I'm sure I didn't type a password for `labuser` again.
- My first idea was that I'd typed my `analyst` password into the `labuser` tile on the login screen by mistake. **The logs ruled that out:** I was already logged in as `analyst` by then, and there's no `analyst` logon after 11:37.
- The event's Subject is `labuser`, with Logon ID **`0x3FB340`**. That's the **same Logon ID** as the successful login at 11:32:06. So the request came **from inside the `labuser` session I'd left open**. That's matched by ID, not just guessed from the timing.
- The program that asked was `msedgewebview2.exe` (Microsoft Edge WebView2, which many Windows features use to show web content), PID `0x2a90` (10896), from its normal install folder. Logon process `Advapi` means a program checked a password through a Windows API, rather than someone typing at the login screen.
- I checked the running process the same day: its parent was PID 2080. **I didn't record which program that was before shutting down the VM**, and the next day it was gone.
- One second earlier (11:37:25) a Windows service started (SYSTEM, logon type 5). I noted it, but **I couldn't link the two**: being close in time isn't proof they're related.
- **My verdict:** harmless (benign true positive), medium confidence. Most likely a Windows feature in the fresh `labuser` session tried a credential check and failed.

## 6. What I did, step by step
| When (local) | What I did | What I got |
|---|---|---|
| 2026-10-27 | Filtered the Security log for 4624/4625 on `labuser` (Event Viewer + PowerShell) | 7 failures, 1 success |
| 2026-10-27 | Widened the filter to `analyst` and logoffs (4647) | Ruled out the "wrong tile" idea |
| 2026-10-27 | Opened the full 4625 from 11:37:26 | Subject `labuser`, caller `msedgewebview2.exe` |
| 2026-10-27 | Looked up PID 10896 with `Get-CimInstance Win32_Process` | Still running; parent PID 2080 |
| 2026-10-27 | Shut down the VM | Lost the running-process details |
| 2026-10-28 ~02:02 | Looked up PID 2080 again | Gone |
| 2026-10-28 ~02:02 | Created `C:\Evidence\exp1` in the VM; exported logs (`wevtutil epl`), timeline CSV, SHA-256 hashes | See evidence list |
| 2026-10-28 02:17 | Copied the evidence from the VM to my PC (`VBoxManage guestcontrol copyfrom`) | Hashes on my PC match the ones from the VM |
| 2026-10-28 02:28–02:42 | Took screenshots (VirtualBox: View → Take Screenshot) | 5 files |
| 2026-10-28 | Read the 11:37:25 event from the exported `Security-full.evtx` on my PC | SYSTEM, type 5, `services.exe` |
| 2026-10-28 | Wrote the incident report | [incident-report.md](incident-report.md) |

## 7. Evidence
Everything is in `evidence/exp1/` on my PC. I hashed the log files (SHA-256) inside the VM when I collected them, and checked the hashes again after copying them to my PC.

| File | What it is | SHA-256 |
|---|---|---|
| `Security-full.evtx` | Full Security log export from `win11-soc` | `ec58052e2cf8f7c2fc2bf38a4cf4d3ec23f5a2fd0e3b09e088fcc2d355d07a16` |
| `exp1-logons.evtx` | Just the relevant events: 4624/4625/4647, `labuser`/`analyst`, 10:27 to 10:45 UTC | `3bbc026d9909d16dcb20e7f8268b657c50f3869edab348ec3a18b4d7fcd134c7` |
| `timeline.csv` | The timeline as a spreadsheet (local + UTC, record ID, key fields) | `bf3b6376cbd854092ecfa22616f69093747eaccf99a540f568cd2461e2464e2f` |
| `screenshots/01-filtered-list.png` | The 6 failures among normal system activity | `ed13bc4a5c6475f92bc01c92c1399c02df47fca663bb06084b314efcefa5a37c` |
| `screenshots/02-4625-first-failure.png` | First failure, 11:28:47 | `ec79fe582e1b23236c2410f13a86b3b1bb355620271364aed5ae5ecacde93563` |
| `screenshots/03-4624-success.png` | The success at 11:32:06, Logon ID `0x3FB340` | `e323e218b6a653d690d35f60bd84d43531d9e9baaa28d04f03fd6722d1bd3f89` |
| `screenshots/04-4625-anomaly-webview2.png` | The 11:37:26 failure from inside the `labuser` session | `1b2f8a536675c973d3ff982a1aec29256b53e5464d6b6c7817bd087298da1d03` |
| `screenshots/05-4624-system-service-noise.png` | An example of background noise (SYSTEM, type 5) | `5e76022caca09d76196d0343bb3712403f7831d9919beb27560818656b0da114` |

One handling slip: the screenshots were first saved to my OneDrive-synced Desktop before I moved them into the evidence folder.

## 8. What I couldn't find out
- **Which app started WebView2.** Windows doesn't log process starts by default (no Sysmon, no event 4688), so PID 2080 can't be identified.
- **Anything that was only in memory.** I shut the VM down before saving the process details.
- This was a simulation with one person and a known story. Nothing came over the network.

## 9. What I'd recommend
1. **Log process starts** (Sysmon, or the "Process Creation" audit policy with command lines), so questions like "who started this?" can be answered later.
2. **Save volatile data before shutting down or cleaning up**: running processes with their parents, network connections, logged-in sessions. Save them to files and hash them.
3. **Set a minimum password length.** It's 0 right now; the CIS Benchmarks recommend 14 or more.
4. **Think about a lower lockout threshold.** It shouldn't be so low that an attacker can lock people out on purpose. Keep the login throttling.
5. **Sign out of sessions you're not using.** My forgotten `labuser` session is what produced the unexplained event.

## 10. Still to do
- [x] Write the incident report from these notes
- [ ] Commit the notes and evidence hashes to git
