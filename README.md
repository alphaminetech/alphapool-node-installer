# AlphaPool node installer

One command turns a fresh server **you own** into an AlphaPool mining node: a pruned **Bitcoin Knots** node plus a
**DATUM gateway** that builds block templates from your own node. Your rigs connect to your server; your server
connects to AlphaPool. AlphaPool gets **no access** to your server.

- Script: `install.sh` (version `2026-10-05.2`). Everything below refers to that file.
- Supported: **Ubuntu 24.04 LTS or Ubuntu 22.04 LTS, x64.** Any other system stops at once with error AP-202, before
  anything is changed.
- Server: **4 GB RAM or more, 80 GB disk or more**, 2 vCPU recommended.
  - Vultr: Cloud Compute "Regular Performance" 2 vCPU / 4 GB / 80 GB (`vc2-2c-4gb`). It is offered in Singapore,
    Tokyo and Seoul. [V7]
  - Contabo: Cloud VPS 4 (4 vCPU / 8 GB / 100 GB). It is offered in Singapore and Japan; Contabo has no Seoul
    location. [C5]

Provider rules: both providers forbid mining ON the server (CPU/GPU hashing). This server does no hashing: it runs a
Bitcoin node and the gateway your rigs connect to. Contabo writes "we fully support the hosting of Crypto-Nodes" [C6].

## Install, form 1: one paste (SSH or the provider's web console)

Log in as root, or as a user with sudo, then paste the command from your AlphaPool dashboard ("My node"). If you are
root on a server without sudo, leave out the word `sudo`. The command looks like this:

```sh
curl -fsSL https://xbt.alphapool.tech/node/install.sh -o ap-node.sh && echo "<SHA256>  ap-node.sh" | sha256sum -c - && sudo bash ap-node.sh --address <PAYOUT_ADDRESS> --node-id <NODE_ID> --token -
```

What the command does:

1. It downloads the installer.
2. It checks the installer's sha256 against the value printed in the command. If they differ, nothing runs.
3. It runs the installer.

The installer asks once for confirmation (`--yes` skips the question). With `--token -` it also asks for the heartbeat
token, without showing it on screen.

You can leave out `--node-id` and `--token`. The node mines exactly the same without them; only the optional status
heartbeat stays off.

The install runs as a background service. If you close the window or lose SSH, it keeps going. To watch it again, run
the same command or `alphapool-node status`.

## Install, form 2: at first boot (cloud-init user data)

Paste the text from your dashboard into the provider's user-data field when you order the server. The server then
installs itself at first boot, with no login needed.

The installer prints that text itself:

```sh
bash ap-node.sh --print-cloud-init --address <PAYOUT_ADDRESS> [--tag "<name>"] [--node-id <ID> --token -]
```

The output is a short `#!/bin/bash` script (about 1.4 KB). It does three things:

1. It downloads this exact installer version.
2. It runs the installer only if the installer's sha256 matches.
3. It passes `--yes --no-follow` and your settings.

Use `--format cloud-config` for a `#cloud-config` version.

- **Vultr.** When you deploy, tick **"Enable Cloud-Init User-Data"** under Additional Features and paste the text.
  - Vultr's docs say a user-data script "begins with a valid shebang", "runs as root and only on the first boot". [V1]
  - Vultr merges a `#cloud-config` over its own vendor data and warns that "overriding many of these values will break
    your instance". [V1] That is why the default output is a shell script, not a `#cloud-config`.
  - Vultr documents no size limit for user data. [V2]
- **Contabo.**
  - Contabo's API takes cloud-init in the `userData` field of `POST /v1/compute/instances` and of the reinstall call.
    The documented example is a `#cloud-config` [C1], so use `--format cloud-config` there.
  - The customer panel has a Cloud-Init switch that is used together with "Reinstall". [C1]
  - Contabo's web order guide shows no user-data field. [C1] For a Contabo server ordered on the web, use form 1.
  - No size limit is documented. [C2]
- **Progress.** Open the provider's web console: the login screen shows the install state and, at the end, the
  address for your rigs.
  - Vultr's console is a browser noVNC terminal. [V4]
  - Contabo needs a VNC client. [C4]
  - You can also log in with SSH and run `alphapool-node status`.
- **If the server reboots during the install**, the install continues by itself after the reboot.
- **The heartbeat token in user data.** Your provider stores user data, and programs on the server can read it back
  through the cloud metadata service. [V6]
  - The token only lets its holder report status for your node.
  - To keep it out of user data, leave `--node-id` out there. After the first login, turn the heartbeat on with
    `sudo alphapool-node heartbeat on <node id>`, which asks for the token.

## What happens (9 steps)

Times below were measured on a 2 vCPU / 4 GB / 80 GB virtual machine (see "Tested").

| step | what | measured |
|---|---|---|
| 1 | system packages (`curl jq aria2 ufw ca-certificates iptables` and the gateway's libraries) | 30 s |
| 2 | user `alphapool`, folders, swap (compressed zram, or a 2 GB file) on servers under 6 GB RAM | (included above) |
| 3 | Bitcoin Knots 29.4.2.knots20260508: download, **sha256 checked before unpacking**, install | 10 s |
| 4 | AlphaPool's DATUM gateway release 3.1: tarball sha256 checked **before unpacking**, binary sha256 checked before installing | 1 s |
| 5 | AlphaPool's chain snapshot (15.7 GB): resumable download, **sha256 checked**, only `blocks/` and `chainstate/` unpacked | 12.5 min download (about 21 MB/s), 31 s check, 71 s unpack. If the snapshot server is full, add the wait for a download slot (below) |
| 6 | configuration: `bitcoin.conf`, gateway config, services | 4 s, steps 6 and 7 together |
| 7 | firewall: your SSH port(s), stratum, Bitcoin peers allowed; everything else incoming denied | (included above) |
| 8 | the node starts | 16 s |
| 9 | the node catches up from the snapshot; then the gateway starts and connects to AlphaPool | 6 min 20 s for 2,076 blocks (snapshot 13 days old), then 21 s |
| | **total, first package to READY** | **about 22 minutes** |

The snapshot was 13 days old in this test. Each week of age adds sync time in step 9.

**Waiting for a download slot.**

- AlphaPool's snapshot server lets 4 servers download at full speed at a time. When all 4 slots are taken, it answers
  "busy" (HTTP 503) or refuses the connection.
- The installer then waits and tries again: after 30 s, then 1, 2 and 4 minutes, then every 5 minutes, with a little
  random spread so waiting servers do not all retry together.
- While it waits, the status shows `step 5/9: waiting for a download slot (N min)`. You can see it with
  `alphapool-node status`, on the provider's web console, and in the optional heartbeat.
- Waiting never counts as a failed attempt. Only real errors count, and those are retried 15 times in a row before the
  install stops with AP-306.
- After a whole day without a free slot, the install stops with AP-307. Run the same command again later: the download
  resumes where it stopped.

At the end you get:

```
  AlphaPool node is READY / AlphaPool 节点已就绪
  Point your rigs at:   stratum+tcp://<this server's public IPv4>:23334
  Worker / user:        anything (for example rig1)    Password: anything
  Payouts go to:        <your payout address>
  Status: alphapool-node status   Logs: alphapool-node logs   Stop: alphapool-node stop   Uninstall: alphapool-node uninstall
```

## Every day: `alphapool-node`

```
alphapool-node status                       node, gateway, rigs, payout address, heartbeat, warnings
alphapool-node logs [node|gateway|install]  recent log lines
alphapool-node start|stop|restart [node|gateway|all]
alphapool-node disable | enable             keep everything off across reboots / back on
alphapool-node heartbeat off | on <id> | status
alphapool-node switch gateway alphapool | file PATH | url URL SHA256 | git REPO_URL COMMIT
alphapool-node switch knots alphapool | url URL SHA256 | dir PATH
alphapool-node set address <payout address> | set tag "<block name>"
alphapool-node gateway-page                 how to open the gateway's own page through SSH
alphapool-node repair                       run the installer again with the saved settings
alphapool-node uninstall [--keep-chain]
```

## What it does, and what it never does

**AlphaPool gets no access to your server.**

- The installer adds no SSH key and no allowlist of AlphaPool addresses.
- It installs no helper that AlphaPool could run and opens no channel for remote commands.
- It sets up no automatic updates from AlphaPool.
- Your SSH configuration, keys and users are not touched.
- The tests compare the whole filesystem before and after an install and fail if anything under `/root`, `/etc/ssh`,
  `/etc/sudoers*` or any `.ssh` folder changes.

**Heartbeat (optional).** It is installed only when you give `--node-id` and a token. Every 20 s, a small agent
running as the unprivileged node user sends this to `https://xbt.alphapool.tech/api/node/heartbeat`:

- sync height and progress, and peer count;
- snapshot-restore progress;
- whether the node and the gateway run;
- the number of connected rigs;
- whether the live job pays AlphaPool;
- the stratum host:port;
- the sha256 of the running gateway binary.

It never sends RPC credentials, the gateway admin password, keys, config files or rig passwords. The reply is thrown
away. The token reaches the agent through systemd credentials, from `/etc/alphapool/heartbeat.token` (root, 0600).

Turn it off at any time with `alphapool-node heartbeat off`, or with `systemctl disable --now alphapool-heartbeat.timer`.

**Firewall (ufw).**

- It adds rules only. It never resets your firewall or removes your rules.
- Rules added:
  - your SSH port(s): detected from `sshd -T`, the sshd/ssh.socket listeners and the current session, plus any
    `--ssh-port`;
  - the stratum port (23334, plus `--alias-ports` if you give them);
  - Bitcoin peers on 8333.
- Then it sets "deny incoming" and enables ufw. The SSH rules always go in first.
- Node RPC (8332) and the gateway's admin page (7152) listen on 127.0.0.1 only and are never opened.
- `--firewall off` leaves ufw alone. If you turn ufw off later, a re-run leaves it off.

**Provider firewalls.**

- The installer asks `ifconfig.co` to connect back to the stratum port and warns if it cannot. `--no-port-check`
  skips this; it sends your server's IP and the port number to ifconfig.co.
- Vultr: firewall groups are optional; once attached they "use a default-deny policy". [V5] Add a rule TCP 23334 from
  anywhere under Products > Network > Firewall.
- Vultr documents that its images ship with the OS firewall on and only SSH open [V5]; the installer adds its rules to that.
- Contabo: "by default, Contabo does not restrict any port access". Its optional firewall drops all incoming traffic
  until you add rules. [C3]

**Updates.**

- It does not turn off your server's own security updates: nobody else patches your server.
- It tells `needrestart` never to restart the node or the gateway by itself, so a library update never bounces your
  rigs. Restart them when it suits you: `alphapool-node restart`.

**Downloads.**

- Every file AlphaPool's defaults download is pinned in the script (https URL + sha256) and checked before it is used.
  The pins live in the script, never on the download host.
- Archives are checked before unpacking: no links, devices, absolute paths or `..`, and the snapshot may hold
  `blocks/` and `chainstate/` only.

## Files: where everything lives (change anything by hand)

| what | where |
|---|---|
| node binaries | `/usr/local/bin/bitcoind`, `/usr/local/bin/bitcoin-cli` |
| node data and settings | `/home/alphapool/.bitcoin/` (`bitcoin.conf`, `blocks/`, `chainstate/`) |
| gateway binary and settings | `/home/alphapool/datum_gateway/datum_gateway`, `datum_gateway_config.json`, `identity.key` |
| services | `/etc/systemd/system/knots-node.service`, `datum-gateway.service`, `alphapool-gateway-start.service` (starts the gateway once the node is at the tip), `alphapool-heartbeat.{service,timer}`, `alphapool-swap.service`, `datum-port-aliases.service` |
| your settings | `/etc/alphapool/node.conf` (address, block name, ports, choices) |
| what the installer installed and wrote | `/etc/alphapool/state` (sha256s), `/etc/alphapool/versions` |
| the installer itself and helpers | `/usr/local/lib/alphapool/` (`install.sh`, `heartbeat-agent`, `start-gateway-when-synced`, `swap-on/off`) |
| the everyday command | `/usr/local/sbin/alphapool-node` |
| log | `/var/log/alphapool-node.log` |

**Your edits are kept.**

- A re-run rewrites `bitcoin.conf` or a unit file only if it is exactly what the installer wrote last time. If you
  changed it, it stays as it is, and the installer's version goes next to it as `<file>.alphapool-new`.
- In the gateway config, a re-run updates only AlphaPool's keys: payout address, block name, pool host, port and key,
  stratum port, RPC login. It keeps every other key you set.
- For services, prefer systemd drop-ins (`systemctl edit datum-gateway`). The installer never touches them.

## Your software, your choice

- The default is AlphaPool's tested combination: Knots 29.4.2.knots20260508 and AlphaPool's gateway release 3.1.
- You can install any other build, now (`--gateway-file`, `--gateway-url` + `--gateway-sha256`, `--gateway-git` +
  `--gateway-commit`, `--knots-url` + `--knots-sha256`, `--knots-dir`) or later (`alphapool-node switch ...`).
- The installer warns when a build is not the tested one, and never refuses it.
- Anything downloaded from a URL is checked against the sha256 you give.
- **Re-running the installer never replaces software you chose or swapped in by hand.** Only an explicit
  `alphapool-node switch ... alphapool` goes back to AlphaPool's build.
- Compatibility:
  - The node must follow the same chain and rules as AlphaPool: Knots 29.4.2 or later in that line.
  - AlphaPool tests its own gateway build only. Other builds may handle AlphaPool's payout list differently.

**AlphaPool's one requirement: `blockmaxweight=740000` or lower.**

- AlphaPool pays every miner directly in the coinbase transaction of each block, and that payout list needs room in
  the block.
- This chain's blocks hold at most 800,000 weight units, and Knots fills a template up to `blockmaxweight` minus
  8,000. 740000 therefore leaves about 17 KB for the payout list.
- With a higher value, a busy mempool can leave too little room, and your gateway cannot build an AlphaPool job.
- The installer writes 740000 and warns, but never blocks, if your `bitcoin.conf` says more. `alphapool-node status`
  shows the same warning.

## Chain data: snapshot, assumeutxo or full sync

| mode | how | time to mining | trust |
|---|---|---|---|
| `--sync snapshot` (default) | download AlphaPool's pinned 15.7 GB snapshot of `blocks/` + `chainstate/` from a pruned node with this exact config, check its sha256, unpack | under an hour (see "Tested") | you trust that AlphaPool's chainstate is correct. The sha256 proves you got exactly the published file, not that its UTXO set is right; the node does not re-validate history from before the snapshot |
| `--sync assumeutxo` | Knots' assumeutxo: after the block headers arrive, load a UTXO file whose hash is **compiled into Knots**, mine from the tip, and validate the full history in the background | about an hour after the download | the UTXO hash is reviewed in Knots' source and the node later checks it against its own full validation. It needs a Knots build that carries that snapshot height in its chainparams (until Knots ships it: a patched build via `--knots-url`/`--knots-dir`) and `--utxo-url/--utxo-sha256/--utxo-bytes/--utxo-height`. Background validation downloads and checks the whole chain for days on a small server |
| `--sync network` | ordinary sync from peers | days on a small server | no shortcut at all |

- The installer is built so that assumeutxo can become a pinned default: set `UTXO_*` and a patched-Knots pin in the
  script. The flow is already implemented and tested: wait for headers, check disk, download, check sha256, pause peers,
  `loadtxoutset`, resume peers, delete the file.
- No UTXO file is pinned today.

## Uninstall

`alphapool-node uninstall` removes:

- the services, the binaries and the `alphapool` user with all chain data;
- `/etc/alphapool`, the helpers, the swap and the needrestart rule;
- the firewall rules it added. It never removes the SSH rule, and it turns ufw off again only if ufw was off before the
  install.

`--keep-chain` keeps `/home/alphapool/.bitcoin`, so a new install reuses it. The system packages stay installed.

## Error codes

| code | meaning |
|---|---|
| AP-100 | unknown option / no terminal to ask in (add `--yes`) |
| AP-101 | payout address missing or invalid (checksum, network or a witness version the gateway cannot pay) |
| AP-102 | block name not allowed (1-16 printable characters; reserved names; names explorers credit to another pool) |
| AP-103 | port not usable |
| AP-104 / 105 / 106 | bad `--public-host` / `--sync` options / `--firewall` value |
| AP-110 / 111 | heartbeat node id / token missing or malformed; token file not root-only |
| AP-120 / 121 | bad gateway / Knots software option |
| AP-200 … 209 | server not suitable: not root, unsupported OS, not x86_64, no systemd, too little memory or disk, clock wrong, port in use, an AlphaPool managed node |
| AP-301 … 307 | network: DNS, a download host, AlphaPool's server (TCP 28916), snapshot on the server differs, download failed, no free download slot for a day |
| AP-401 … 405 | integrity: sha256 mismatch, unsafe archive, no gateway build published for this Ubuntu release |
| AP-501 … 509 | install: apt, user, gateway binary, node start, background service, firewall (ufw) |

## Sources (provider documentation, checked 2026-10-05)

- [V1] Vultr, How to deploy a Vultr server with cloud-init user-data: https://docs.vultr.com/how-to-deploy-a-vultr-server-with-cloudinit-userdata
- [V2] Vultr API, CreateInstanceRequest `user_data` (no size limit stated): https://github.com/vultr/vultr-csharp/blob/main/docs/CreateInstanceRequest.md
- [V3] Vultr, Startup scripts FAQ ("Linux systems use cloud-init user-data"): https://docs.vultr.com/products/orchestration/startup-scripts/faq
- [V4] Vultr Console (noVNC): https://docs.vultr.com/products/compute/instances/cloud-compute/connection/vultr-console
- [V5] Vultr firewall groups (default deny): https://docs.vultr.com/support/products/compute/how-do-i-debug-a-firewall-causing-connection-problems-with-my-vultr-compute-instance ; rules: https://docs.vultr.com/products/network/firewall-groups/management/rules ; OS firewall on by default: https://docs.vultr.com/firewall-quickstart-for-vultr-cloud-servers
- [V6] cloud-init's Vultr datasource reads user data from the metadata service at 169.254.169.254: https://raw.githubusercontent.com/canonical/cloud-init/main/cloudinit/sources/DataSourceVultr.py
- [V7] Vultr plan availability per region (vc2 plans in sgp, nrt, icn): https://api.vultr.com/v2/regions/sgp/availability?type=vc2
- [C1] Contabo API (`userData`, cloud-init): https://api.contabo.com/ ; ordering guide: https://help.contabo.com/en/support/solutions/articles/103000394299-how-to-order-a-contabo-product
- [C2] Contabo API spec (no maximum length for `userData`): https://api.contabo.com/
- [C3] Contabo port access and firewall: https://help.contabo.com/en/support/solutions/articles/103000406861-managing-port-access-and-os-level-firewall-on-your-server ; https://docs.contabo.com/docs/network-services/firewall/
- [C4] Contabo VNC: https://help.contabo.com/en/support/solutions/articles/103000407800-how-to-connect-to-your-server-using-vnc
- [C5] Contabo VPS plans and locations: https://contabo.com/en/vps/ ; https://docs.contabo.com/docs/servers-hosting/vps/
- [C6] Contabo on crypto nodes: https://contabo.com/blog/can-i-use-contabo-servers-for-crypto/ ; VPS terms ("Cryptocurrency mining is not permitted on VPS"): https://docs.contabo.com/docs/servers-hosting/vps/
- cloud-init: user-data scripts run once per instance in the final stage: https://docs.cloud-init.io/en/latest/explanation/format/user-data-script.html
