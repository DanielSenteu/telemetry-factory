# Factory Setup Guide — Machine Data Collector

This little program reads live data from the injection molding machines (through
the TECHMATION tmSCADA-iD201 boxes) and sends it to the cloud dashboard. It runs
on one Windows laptop/PC inside the factory. Once it's running you don't touch
it — it starts with the computer and recovers by itself after power or internet
cuts.

**You need:** the tmSCADA boxes (one per machine), a network switch, Cat5e
ethernet cables, and one laptop/PC that stays in the factory, powered on, with
internet (wifi is fine).

---

## Part 1 — Wire up the boxes

Each machine gets its own box. Each box has two network ports doing different
jobs:

```
Machine 1 ──> Box 1 ──┐
Machine 2 ──> Box 2 ──┼──> SWITCH <── Laptop (cable or wifi)
Machine 3 ──> Box 3 ──┘
```

1. **Power the box**: 9–48V DC, wired from the machine controller's own power
   supply (mind + and − polarity!).
2. **GLAN port → machine controller**, with an ethernet cable.
   - ⚠️ **270-series controller panels need a special cable**: standard
     EIA/TIA-568B wiring but with **pins 7 and 8 left unconnected**. A normal
     shop-bought cable will NOT work on 270 panels. 3354 panels use a normal
     cable.
3. **On the machine's controller screen** (network settings page):
   - Set the machine's own IP to `192.168.13.123` (anything `192.168.13.x`
     except `.150`)
   - Set the server IP to `192.168.13.150` (that's the box)
4. **LAN port → the switch**, with a normal ethernet cable.
5. **Give each box a unique IP on its LAN port.** Every box ships with the same
   default (`192.168.2.130`), so with more than one machine they clash. Set them
   to `192.168.2.131`, `.132`, `.133`, ... one per box. **Write down which IP
   belongs to which machine** — you'll type these into the config file.
6. Connect the **laptop** to the same switch (or the same wifi network the
   switch is on).

**Check it worked:** on the laptop, open Command Prompt and type
`ping 192.168.2.131` — you should get replies. Repeat for each box's IP.

---

## Part 2 — Set up the laptop

1. **Install Node.js**: download the "LTS" installer from
   <https://nodejs.org> and install it (all default options).
2. **Unzip the folder** you were sent, e.g. to `C:\alpha-agent`.
3. **Open Command Prompt** and run:
   ```
   cd C:\alpha-agent
   npm install
   ```
   (one-time, takes a few minutes)
4. **Edit `config.json`** (right-click → Open with → Notepad). Fill in one line
   per machine with the box IPs you wrote down in Part 1:
   ```json
   "machines": [
     { "name": "IMM-1", "endpoint": "opc.tcp://192.168.2.131:16664" },
     { "name": "IMM-2", "endpoint": "opc.tcp://192.168.2.132:16664" }
   ]
   ```
   Use real machine names — they appear on the dashboard exactly as typed.
   **Don't touch `cloudUrl` or `agentToken`** — they're already set.
5. **Run it:**
   ```
   npm run agent
   ```
   You should see `connected` lines for each machine, then a steady stream of
   readings, and `ship_ok` messages every ~10 seconds. That means data is
   flowing to the dashboard. Leave the window open.

---

## Part 3 — Make it survive reboots (do this once it works)

1. **Stop the laptop from sleeping**: Settings → System → Power → set "Sleep"
   to **Never** (both plugged in and battery). This matters — the machines have
   no memory; any minute the collector is off is production data lost forever.
2. **Auto-start on boot**: press Win+R, type `taskschd.msc`, Enter →
   "Create Basic Task":
   - Name: `Alpha machine collector`
   - Trigger: **When the computer starts**
   - Action: **Start a program** → browse to `C:\alpha-agent\start-agent.bat`
   - Finish, then right-click the task → Properties → tick
     **"Run whether user is logged on or not"**.
3. Reboot the laptop and check the dashboard still updates.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `npm install` fails | Laptop has no internet, or Node.js not installed — redo Part 2 step 1 |
| No `connected` line for a machine | Can't reach that box: check the cable, re-check the box's LAN IP, try `ping <box-ip>` |
| `connected` but machine shows offline on dashboard | Box↔machine link: check the GLAN cable (270 special wiring!) and the IP settings on the machine's screen (Part 1 step 3) |
| Readings appear but no `ship_ok` | No internet. Don't worry — everything queues on disk and uploads automatically when internet returns |
| Window closed by accident | Just run `npm run agent` again — nothing was lost while the machines were being read |

Anything else: take a photo of the error in the window and send it back.
