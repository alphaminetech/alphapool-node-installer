# AlphaPool node installer

One command turns a fresh server **you own** into an AlphaPool mining node: a pruned **Bitcoin Knots** node plus a
**DATUM gateway** that builds block templates from your own node. Your rigs connect to your server; your server
connects to AlphaPool. AlphaPool gets **no access** to your server.

- Script: `install.sh` (version `2026-10-09.1`; changes: `CHANGELOG.md`). Everything below refers to that file.
- Supported: **Ubuntu 24.04 LTS or Ubuntu 22.04 LTS, x64.** Any other system stops at once with error AP-202, before
  anything is changed.
- Server: **4 GB RAM or more, 80 GB disk or more**, 2 vCPU recommended.
  - Recommended: **Vultr** Cloud Compute "Regular Performance" 2 vCPU / 4 GB / 80 GB (`vc2-2c-4gb`) with **Ubuntu
    24.04 LTS x64**. It is offered in Singapore, Tokyo and Seoul. [V7]
  - Contabo: Cloud VPS 4 (4 vCPU / 8 GB / 100 GB). It is offered in Singapore and Japan; Contabo has no Seoul
    location. [C5]
- **Your node validates the chain itself.** It starts from a UTXO snapshot that Bitcoin Knots checks against a hash
  compiled into Bitcoin Knots, then validates every block since then. With the official 910000 option that takes **about half
  a day** on a small server. Keep your rigs mining where they are until the installer, or `alphapool-node status`,
  says **READY**. See "How the node gets its chain".

Provider rules: both providers forbid mining ON the server (CPU/GPU hashing). This server does no hashing: it runs a
Bitcoin node and the gateway your rigs connect to. Contabo writes "we fully support the hosting of Crypto-Nodes" [C6].

### Default fast start (2026-10-09.1)

New nodes use Chris Guida's Bitcoin Knots 29.4.2 + PR444 build and snapshot **976000**: the build is verified by the release-builder signatures on its `SHA256SUMS` (published next to the archive) plus the archive sha256 pinned here, and the snapshot by its pinned sha256 and then by Bitcoin Knots itself. The total start is **about half an hour**, depending on download speed and the blocks left to validate; status reports measured progress and time left.

The build is the official 29.4.2 source plus the one chainparams commit of PR #444, reproduced with Guix and attested on https://github.com/chrisguida/guix.sigs/tree/assumeutxo976000 (one of the seven 29.4.2 release builders so far; more attestations are being solicited). When a signed Bitcoin Knots release includes this snapshot, the upgrade command moves your node to that release.

该构建版是官方 29.4.2 源码加上 PR #444 的一个 chainparams 提交，用 Guix 复现并在 https://github.com/chrisguida/guix.sigs/tree/assumeutxo976000 上签署（目前为 29.4.2 的七位发布构建者之一，正在征集更多签名）；当签名发布版包含同一快照后，升级命令会将您的节点升级到该版本。

Use `--start official` for the builder-signed release and its 910000 snapshot (one to two days). Existing .6 nodes keep their mode and chain state on upgrade and continue catching up; changing the default does not load a new snapshot over existing data. There is no torrent download or seeding in this version. The detailed 910000 timings below describe the official option.


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

The output is a short `#!/bin/bash` script (about 2 KB). It does three things:

1. It downloads this exact installer version.
2. It runs the installer only if the installer's sha256 matches.
3. It passes `--yes --no-follow` and your settings: every option you add to the command above is passed on (the
   stratum port, `--start`, `--sync`, the `--utxo-*`, `--knots-*` and `--gateway-*` options, `--ssh-port`, `--firewall off`,
   `--no-port-check`). Only `--knots-dir` and `--gateway-file` cannot be used here: they name files on your own
   computer, which the new server does not have (AP-131).

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
- **Progress.** Open the provider's web console: the login screen shows the install state, then the blocks left and
  the time left, and at the end READY with the address for your rigs.
  - Vultr's console is a browser noVNC terminal. [V4]
  - Contabo needs a VNC client. [C4]
  - You can also log in with SSH and run `alphapool-node status`.
- **If the server reboots during the install**, recovery is attempted automatically. If it reports AP-416 while
  Bitcoin Knots is still starting or cannot be inspected safely, pending state is kept. Wait for startup to finish
  or resolve the reported inspection problem, then run the same install command again.
- **The heartbeat token in user data.** Your provider stores user data, and programs on the server can read it back
  through the cloud metadata service. [V6]
  - The token only lets its holder report status for your node.
  - To keep it out of user data, leave `--node-id` out there. After the first login, turn the heartbeat on with
    `sudo alphapool-node heartbeat on <node id>`, which asks for the token.

## What happens (9 steps)

Times were measured on a 2 vCPU / 4 GB / 80 GB virtual machine (see "Tested").

| step | what | measured |
|---|---|---|
| 1 | system packages (`curl jq aria2 ufw gpgv ca-certificates iptables` and the gateway's libraries) | 30 s |
| 2 | user `alphapool`, folders, swap (compressed zram, or a 2 GB file) on servers under 6 GB RAM | (included above) |
| 3 | Bitcoin Knots: download; an official release is checked against builder signatures and its pinned sha256, a developer build against the sha256 this installer pins; install | 10 s |
| 4 | AlphaPool's DATUM gateway release 3.1: tarball sha256 checked **before unpacking**, binary sha256 checked before installing | 1 s |
| 5 | the UTXO snapshot of block 910,000 (9.6 GB): the installed Bitcoin Knots is asked whether it knows that snapshot; then a resumable download, **sha256 checked**, and the file's own header checked | depends on your line (9.6 GB). If the download server is full, add the wait for a download slot (below) |
| 6 | configuration: `bitcoin.conf`, gateway config, services | 4 s, steps 6 and 7 together |
| 7 | firewall: your SSH port(s), stratum, Bitcoin peers allowed; everything else incoming denied | (included above) |
| 8 | the node starts | 16 s |
| 9 | the node gets the block headers from the network, then **loads the snapshot** (Bitcoin Knots checks its content against the hash compiled into it). The install is complete here | headers about 3 min, load about 10 min |
| | **after the install: the node validates every block since the snapshot, by itself.** The gateway starts by itself when the node is at the chain tip, and `alphapool-node status` then says READY | **one to two days** on a small server; status shows measured time left |

How long the last part takes depends mostly on how fast other Bitcoin nodes hand out blocks to yours, not on your
server. The installer watches the first minutes, prints the blocks left and (once it can be measured) the time left,
and then returns. Nothing is lost by waiting: your server takes no rigs before READY, so **keep your rigs mining
where they are** until then.

**Where you see progress.**

- `alphapool-node status`: the first line says `READY` or `NOT READY yet`, with the blocks left and the time left at
  the speed your node really had in the last minutes.
- The login screen of the provider's web console shows the same line, renewed every few minutes, and READY with the
  address for your rigs at the end.
- `alphapool-node status` never waits for a busy node: each question to the node is given 4 seconds, and after the
  first one that gets no answer it shows the figures of the last measurement instead.

**Waiting for a download slot.**

- AlphaPool's download server admits a limited number of snapshot downloads at a time. When every slot is taken, it
  answers "busy" (HTTP 503) or refuses the connection.
- The installer then waits and tries again: after 30 s, then 1, 2 and 4 minutes, then every 5 minutes, with a little
  random spread so waiting servers do not all retry together.
- While it waits, the status shows `step 5/9: waiting for a download slot (N min)`. You can see it with
  `alphapool-node status`, on the provider's web console, and in the optional heartbeat.
- Waiting never counts as a failed attempt. Only real errors count, and those are retried 15 times in a row before the
  install stops with AP-306.
- After a whole day without a free slot, the install stops with AP-307. Run the same command again later: the download
  resumes where it stopped.

At the end of the install you get:

```
  AlphaPool node installed / AlphaPool 节点已安装 (the gateway starts once the node has caught up)
  Point your rigs at:   stratum+tcp://<this server's public IPv4>:23334
  Worker / user:        anything (for example rig1)    Password: anything
  Payouts go to:        <your payout address>
  Status: alphapool-node status   Logs: alphapool-node logs   Stop: alphapool-node stop   Uninstall: alphapool-node uninstall
NOT READY yet: keep your rigs mining where they are until this says READY. How far it is: alphapool-node status

The install is complete, and the node is NOT READY yet. It is validating 65,976 blocks: time left is still being measured.
```

and when the node is at the chain tip, `alphapool-node status` and the login screen say:

```
  state    : READY - your rigs can mine here
```

## How the node gets its chain

**The validated start (default).**

1. The node loads a **UTXO snapshot**: the set of all unspent coins as of one block. Bitcoin Knots accepts such a
   snapshot only for a block that is **compiled into Bitcoin Knots**, and only if the snapshot's content has the
   hash that is compiled in as well. AlphaPool cannot change either: both are part of the selected Bitcoin Knots
   build. The installer checks an official release against its builders' signatures and a developer build against
   the sha256 it pins (see "How Bitcoin Knots is verified").
2. From that block on, **your node validates every block itself**, up to the chain tip. Only then does the gateway
   start.
3. In the background the node also validates the **whole history before the snapshot** and compares the result with
   the snapshot. This takes days on a small server, does not affect mining, and `alphapool-node status` shows how
   far it is (`history check: block N of 910,000`).

**Start modes.** A Bitcoin Knots build and the snapshot it starts from belong together, so the installer treats
them as one thing, a *start mode*: the build (version, archive, sha256, and who vouches for it), the block heights
that build knows, the snapshot a new node starts from, and how long the node then validates. The modes are a short
table in the installer; `--help` lists them, each with one sentence that says what you are trusting.

- This version has one mode, `official`: the official Bitcoin Knots 29.4.2.knots20260508 release, checked against
  its builders' signatures, starting from block 910,000, the newest block that release knows. That block is about
  66,000 blocks back, which is why the official start is estimated at one to two days.
- `--start NAME` chooses a mode. Without it a new install takes the installer's default mode.
- When a Bitcoin Knots build carries a newer block, AlphaPool adds a mode (or changes one); the start is then much
  shorter. If such a build is not signed by the Bitcoin Knots release builders, the installer says so in the plan
  before it installs anything, in `--help` and in `alphapool-node status`, and the `official` mode stays available.
- **Nodes that are installed already need nothing**: they have their chain, and they keep their mode. A later
  default does not move them.

What the installer does around it:

- Before the 9.6 GB are downloaded, the installed Bitcoin Knots is **asked** whether it knows the snapshot. It runs
  for a moment on an empty scratch folder, with no network; nothing of your node is touched. A build that does not
  know the block is refused there (AP-411), with the heights it does know.
- The file's sha256 is checked, and its own header: it must be a UTXO snapshot, of this network, of the expected
  block (AP-412).
- The file is handed to the node in `/var/lib/alphapool-handover`, a directory of root's that the node's user may
  read and not write. The node reads it from there; root deletes it afterwards. Nothing is put into the node's own
  folder by root.
- **If snapshot validation or loading fails, the node is stopped** and the error says what to do. AP-416 instead
  preserves the node and pending state because an import is active or cannot be inspected safely. A node left
  running without its snapshot would sync the whole chain from the network, for days, without telling anyone.
  Run the same command again: it goes
  on where it stopped (the download resumes; a file that is checked already is not downloaded again).
- After a reboot, recovery is attempted automatically. AP-416 can require a manual retry after node startup or
  after the reported inspection problem is resolved; run the same command again.

**Other ways.**

| option | what | time | 
|---|---|---|
| (default) | the 976000 fast start | about half an hour |
| `--start official` | the signed 910000 start | one to two days |
| `--start NAME` | the validated start of another start mode of the installer (`--help` lists them) | that mode's duration |
| `--utxo-height N` | the validated start from another snapshot of the installer's list | depends on the block |
| `--utxo-url URL --utxo-sha256 HEX --utxo-bytes N --utxo-height N` | the validated start from a UTXO snapshot file you name. Your Bitcoin Knots build must have that block compiled in; the installer asks it before it downloads | depends on the block |
| `--sync network` | ordinary sync of everything from the Bitcoin network | days on a small server |

AlphaPool's pre-synced copy of a node's chain folders, the start of installer versions before 2026-10-08.1, is not
offered any more (`--sync snapshot` stops with AP-105): a node validates its chain itself. This installer never
replaces chain data that is already on a server.

## Every day: `alphapool-node`

```
alphapool-node status                       node, gateway, rigs, payout address, heartbeat, warnings
alphapool-node logs [node|gateway|install]  recent log lines
alphapool-node start|stop|restart [node|gateway|all]
alphapool-node disable | enable             keep everything off across reboots / back on
alphapool-node heartbeat off | on <id> | status
alphapool-node switch gateway alphapool | file PATH | url URL SHA256 | git REPO_URL COMMIT
alphapool-node switch knots alphapool | url URL [SHA256] | dir PATH
alphapool-node upgrade [--yes] [--knots alphapool] [--gateway alphapool]   to the installer's pinned versions, in place
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
- **Your node gets no fixed peers of AlphaPool's.** `bitcoin.conf` has no `addnode`, `connect` or `seednode` line:
  your node finds its peers by itself, like any Bitcoin node.
- The tests compare the whole filesystem before and after an install and fail if anything under `/root`, `/etc/ssh`,
  `/etc/sudoers*` or any `.ssh` folder changes.

**Heartbeat (optional, off by default).** Nothing is reported to AlphaPool unless you turn the heartbeat on, and it
is on only when you give BOTH a node id (`--node-id`) and its token. Then, every 20 s, a small agent running as the
unprivileged node user sends this to `https://xbt.alphapool.tech/api/node/heartbeat`:

- sync height and progress, and peer count;
- progress of the snapshot download and load;
- whether the node and the gateway run;
- the number of connected rigs;
- whether the live job pays AlphaPool;
- the stratum host:port;
- the sha256 of the running gateway binary.

It is status only. It never sends RPC credentials, the gateway admin password, keys, config files or rig passwords.
The reply is thrown away: nothing AlphaPool sends back is read or run. The token reaches the agent through systemd
credentials, from `/etc/alphapool/heartbeat.token` (root, 0600).

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
- The gateway archive is checked before anything is read from it: no links, devices, absolute paths or `..`.
- Downloads, files while they are checked, and the installer's logs are kept in `/var/lib/alphapool`, a directory
  only root can enter. The installer makes it. If the path is there already, it must be a real directory that belongs
  to root and that nobody else can write to; otherwise the installer stops (AP-211). Nothing is put in `/tmp`,
  `/var/tmp` or `/var/log`.

**Root and the node user's folders.** The node and the gateway run as the unprivileged user `alphapool`, and their
folders (`/home/alphapool/.bitcoin`, `/home/alphapool/datum_gateway`) belong to that user. The installer keeps to
one rule: root never reads, writes, moves, removes or changes the owner of anything through those folders. Whatever
is in them is read and written by a process of the `alphapool` user itself; whatever root owns (the programs, the
downloads, the logs, the snapshot file while the node loads it) lives in directories that only root can change.
A program of that user can therefore never trick the installer into touching another file on your server. The same
holds for a file you name yourself with `--gateway-file` or `--knots-dir` if it lies in that user's home.

## Files: where everything lives (change anything by hand)

| what | where |
|---|---|
| node programs | `/usr/local/bin/bitcoind`, `/usr/local/bin/bitcoin-cli` (links into the active software set) |
| node data and settings | `/home/alphapool/.bitcoin/` (`bitcoin.conf`, `blocks/`, `chainstate/`; `chainstate_snapshot/` until the history check is done) |
| gateway program and settings | `/home/alphapool/datum_gateway/datum_gateway` (a link into the active software set), `datum_gateway_config.json`, `identity.key` (the gateway's own key: no install, upgrade or switch touches it) |
| software sets | `/usr/local/lib/alphapool/sets/<name>/` holds `bitcoind`, `bitcoin-cli`, `datum_gateway` and `set.info` (their sha256 and source). `/usr/local/lib/alphapool/current` is a link to the active set. The set from before the last change is kept as the way back |
| services | `/etc/systemd/system/knots-node.service`, `datum-gateway.service`, `alphapool-gateway-start.service` (starts the gateway once the node is at the tip, and shows the progress until then), `alphapool-heartbeat.{service,timer}`, `alphapool-swap.service`, `datum-port-aliases.service`, `alphapool-install-resume.service` (after a reboot it continues an install, or settles an upgrade, that was cut short; otherwise it does nothing) |
| your settings | `/etc/alphapool/node.conf` (address, block name, ports, choices) |
| what the installer installed and wrote | `/etc/alphapool/state` (sha256s, how the node got its chain), `/etc/alphapool/versions` |
| the installer itself and helpers | `/usr/local/lib/alphapool/` (`install.sh`, `heartbeat-agent`, `start-gateway-when-synced`, `swap-on/off`) |
| the everyday command | `/usr/local/sbin/alphapool-node` |
| logs | `/var/lib/alphapool/log/` (root only): `install.log`, `apt.log`, `cloud-init.log`. Read them with `alphapool-node logs install` |
| downloads and scratch files | `/var/lib/alphapool/` (root only): `dl/` holds the snapshot while it downloads, `tmp/` one scratch directory per run. Both are empty when no run is in progress |
| the snapshot while the node loads it | `/var/lib/alphapool-handover/` (root's; the node user may read it). Empty afterwards |
| a validated start in progress | `/etc/alphapool/validated-start.journal`: there from step 5 until the node has loaded the snapshot |
| an upgrade in flight | `/etc/alphapool/upgrade.journal`: there only while an upgrade runs, or after one was cut short |

**Putting a program of your own in place.** The three program paths are links. (On a node installed by a version
before 2026-10-07.2 a path stays a plain file until the first upgrade of that program.) Replace the link with your file,
for example `sudo install -m 0755 my-bitcoind /usr/local/bin/bitcoind`, or use `alphapool-node switch ...`. From then
on that program is yours, and no upgrade or re-run touches it. Bitcoin Knots counts as a pair: if you replace
`bitcoind` or `bitcoin-cli`, both are treated as yours.

**Your edits are kept.**

- A re-run rewrites `bitcoin.conf` or a unit file only if it is exactly what the installer wrote last time. If you
  changed it, it stays as it is, and the installer's version goes next to it as `<file>.alphapool-new`.
- Edit `bitcoin.conf` as the node's user (`sudo -u alphapool nano /home/alphapool/.bitcoin/bitcoin.conf`), or give it
  back afterwards (`chown alphapool:alphapool`). A file that belongs to root there cannot be read by the node; the
  installer then tells you so and changes nothing.
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
- AlphaPool's gateway archives are built from the public source at
  [alphaminetech/datum_gateway](https://github.com/alphaminetech/datum_gateway), branch `alphapool`, commit
  `90f01b76625f5936febdc2389759c462467a750a`. The repository's `contrib/reproducible/build.sh` and its README
  explain how to rebuild the archives and compare their sha256. `--help`, `alphapool-node help`, the upgrade plan
  and `alphapool-node status` name this repository and commit. You can build it yourself with
  `--gateway-git https://github.com/alphaminetech/datum_gateway.git --gateway-commit 90f01b76625f5936febdc2389759c462467a750a`.
  A build you make reports the same source version but may have different bytes; the installer treats it as your
  own build and keeps it on later upgrades.
- Compatibility:
  - The node must follow the same chain and rules as AlphaPool: Knots 29.4.2 or later in that line.
  - AlphaPool tests its own gateway build only. Other builds may handle AlphaPool's payout list differently.
  - A Bitcoin Knots build of your own starts from a snapshot only if it has that snapshot's block compiled in. The
    installer asks your build which of its snapshots it knows, and says so if it knows none (AP-122): then name a
    snapshot yourself (`--utxo-*`) or use `--sync network`.
  - While a node that started from a snapshot is still checking its history, it can only run on a Bitcoin Knots
    build that knows that snapshot's block. A switch or an upgrade to a build that does not is refused before
    anything is changed (AP-414); it goes through once the history check is done.

**AlphaPool's one requirement: `blockmaxweight=740000` or lower.**

- AlphaPool pays every miner directly in the coinbase transaction of each block, and that payout list needs room in
  the block.
- This chain's blocks hold at most 800,000 weight units, and Knots fills a template up to `blockmaxweight` minus
  8,000. 740000 therefore leaves about 17 KB for the payout list.
- With a higher value, a busy mempool can leave too little room, and your gateway cannot build an AlphaPool job.
- The installer writes 740000 and warns, but never blocks, if your `bitcoin.conf` says more. `alphapool-node status`
  shows the same warning.

## Upgrade (in place, no new sync): one command for everything that comes later

When Bitcoin Knots or the gateway needs a new version, or the installer itself gains something, AlphaPool publishes
a new installer. Paste the upgrade command from your dashboard. It looks like this:

```sh
curl -fsSL https://xbt.alphapool.tech/node/install.sh -o ap-node.sh && echo "<SHA256>  ap-node.sh" | sha256sum -c - && sudo bash ap-node.sh --upgrade
```

**A node never has to be installed again.** That one command brings an installed node everything a later installer
has, with no new sync:

- Bitcoin Knots and the gateway, moved to the versions the new installer pins;
- everything else the installer writes: the `alphapool-node` command, the gateway starter, the service units and
  the optional heartbeat agent. They are renewed even when both programs are current already; the node is not
  restarted for that, and a unit you edited is kept (the new version goes next to it as `<file>.alphapool-new`).

What the upgrade of the programs does:

- It prints the versions before and after, and asks once (`--yes` skips the question).
- It downloads and checks the new software BEFORE anything is stopped: an official Bitcoin Knots release against
  builder signatures and pinned sha256, a developer build against the sha256 this installer pins, and the gateway
  against its pinned sha256.
- The new programs go into a software set of their own, and the programs installed now are kept as a set too: the
  way back.
- It stops the gateway, then the node; makes the new set the active one in a single step, so all programs change
  together or none does; starts the node, and starts the gateway once the node is back at the tip. Your rigs are
  without work for about a minute and reconnect by themselves. If only the gateway changes, the node is not stopped.
- **Nothing else is touched:** chain data (no new sync), `bitcoin.conf`, the gateway settings and the gateway's
  identity key, the firewall and your own edits stay exactly as they are.
- **If anything fails, the previous programs are put back and started again.** That covers a new node that does not
  start (AP-511), a gateway that does not come back (AP-512), a service that cannot be stopped (AP-515) and a set
  that cannot be made active (AP-503). The command then ends with an error. It reports success only when the node,
  and the gateway if it ran before, run the new programs.
- **If the upgrade is cut short** (the installer is killed, the server loses power or reboots), it is finished from
  its journal, or the previous programs are put back. Recovery is attempted automatically when the server starts
  again, or when you run the upgrade command again. An AP-416 refusal keeps the journal; wait for node startup to
  finish or resolve the inspection problem, then run the upgrade command again. Until recovery finishes,
  `alphapool-node status` says that an upgrade was cut short.
- **Exit code 3 (AP-513)** means: the new programs are in place, but the gateway, which ran before, is not back yet
  because the node has not caught up with the network. Until it is back your rigs have no work from this server.
  The gateway starts by itself; `alphapool-node status` shows when. An upgrade that was cut short and finished
  later ends the same way.
- Only one install or upgrade runs at a time. A second command started meanwhile changes nothing. (An uninstall
  stops a running install or upgrade first: that is what it is for.)
- Running it again changes nothing ("Nothing to upgrade").
- **Your own builds are left alone.** If you switched to your own Bitcoin Knots or gateway, or replaced `bitcoind`,
  `bitcoin-cli` or the gateway by hand, the upgrade says so and leaves it. To replace it with AlphaPool's pinned
  versions, add `--knots alphapool` and/or `--gateway alphapool`.
- An installer older than the one your node's software came from never downgrades it.
- **A node keeps its start mode.** The upgrade moves it to its mode's build in the new installer. `--upgrade --start
  NAME` moves it to another mode of that installer. A node that started from a snapshot and has not finished its
  history check can only run on a Bitcoin Knots build that knows that snapshot's block: an upgrade to a build that
  does not is refused before anything is stopped (AP-414). If that could not be told beforehand and the new node
  does not start for this reason, the previous programs are put back and the message says so.

Afterwards, `alphapool-node upgrade` repeats the upgrade with the installer already on your server.
`alphapool-node status` shows the installed versions, and says "newer pinned version available" or "newer pinned
build available" when that installer pins another Bitcoin Knots or gateway build than the one that runs. Re-running a
newer installer in the normal way (the install command) upgrades through the same path.

Nodes installed by an earlier installer run an earlier build of gateway release 3.1. Upgrading to this version
moves the gateway to the public build above: the gateway restarts once, Bitcoin Knots is not stopped, and the
gateway's settings and identity key stay as they are.

## How Bitcoin Knots is verified

Bitcoin Knots is installed or upgraded only when all of this holds:

1. The release's `SHA256SUMS.asc` (downloaded next to the archive) carries at least one **valid signature from a
   Bitcoin Knots release builder key pinned in the installer**. The installer prints which pinned keys signed.
2. The signed `SHA256SUMS` lists the downloaded archive exactly once: same file name, same sha256. A file that
   names the archive twice is refused.
3. For AlphaPool's pinned version, the archive also matches the sha256 pinned in the installer.

Otherwise nothing is installed (errors AP-406, AP-407, AP-401; AP-308 if the signature files cannot be downloaded).

The pinned keys are the 7 builders whose signatures are on the 29.4.2.knots20260508 release. The keys and their
fingerprints come from the official builder-keys directory of the Bitcoin Knots release signatures,
<https://github.com/bitcoinknots/guix.sigs> (branch `knots`, commit `278e3aeac8ce78c915940b25b3c3bcb9c9f0598e`):

```
1A3E761F19D2CC7785C5502EA291A2C45D0C504A
658E64021E5793C6C4E15E45C2E581F5B998F30E
95636F3538D9262765AB29BEE952E584CA8C0F45
314B8D611A0C0468498C35C52018C90B857A0571
1D5889CB9E0564C154E18BB512EC9519DB43CC27
A47D99B6DB0D715D40C59A2023AE8A8EA7E24E38
DAED928C727D3E613EC46635F5073C4F4882FFFC
```

The keys themselves are inside the installer, so no keyserver is needed. `gpgv` does the check.

For your own Knots archive (`--knots-url` or `alphapool-node switch knots url <URL>`) there are two cases:

- **You give no sha256.** The same signature check applies: `SHA256SUMS.asc` must be next to the archive and carry a
  valid signature from a pinned key, or nothing is installed.
- **You give its sha256 (`--knots-sha256`).** Then YOUR sha256 decides. The installer still looks at the signatures
  and prints a warning when they are missing, not valid, or made by a builder whose key is not pinned, but it
  installs the archive if it matches your sha256. This is deliberate: you may run a build from a builder the
  installer does not know. If you want the signature check to be binding, do not pass a sha256.

## Uninstall

`alphapool-node uninstall` removes:

- the services, the programs and the `alphapool` user with all chain data;
- `/etc/alphapool`, the helpers, the swap and the needrestart rule;
- the firewall rules it added. It never removes the SSH rule, and it turns ufw off again only if ufw was off before the
  install.

The files in the `alphapool` user's home are removed by a process of that user; root then removes the user and the
empty home folder. `--keep-chain` keeps `/home/alphapool/.bitcoin`, so a new install reuses it. The system packages
and the logs in `/var/lib/alphapool/log` stay.

## Error codes

| code | meaning |
|---|---|
| AP-100 | unknown option / no terminal to ask in (add `--yes`) |
| AP-101 | payout address missing or invalid (checksum, network or a witness version the gateway cannot pay) |
| AP-102 | block name not allowed (1-16 printable characters; reserved names; names explorers credit to another pool) |
| AP-103 | port not usable |
| AP-104 / 105 / 106 | bad `--public-host` / `--sync`, `--start` or `--utxo-*` options (also: `--sync snapshot`, which is no longer offered) / `--firewall` value |
| AP-110 / 111 | heartbeat node id / token missing or malformed; token file not root-only |
| AP-120 / 121 | bad gateway / Knots software option |
| AP-122 | the validated start is not possible: the installer has no UTXO snapshot that this Bitcoin Knots build knows |
| AP-130 / 131 | bad `--print-cloud-init` options; `--knots-dir` or `--gateway-file` in user data (the new server does not have those files) |
| AP-200 … 211 | server not suitable: not root, unsupported OS, not x86_64, no systemd, too little memory or disk, clock wrong, port in use, an AlphaPool managed node, no node to upgrade, `/var/lib/alphapool` or `/var/lib/alphapool-handover` is not root's alone (211) |
| AP-301 … 309 | network: DNS, a download host, AlphaPool's server (TCP 28916), the snapshot on the server differs, download failed, no free download slot for a day, the Knots signature files could not be downloaded, the node found no peers or got no block headers (309: allow outgoing TCP 8333) |
| AP-401 … 407 | integrity: sha256 mismatch, unsafe archive, no gateway build published for this Ubuntu release, no valid signature from a pinned Bitcoin Knots builder key (406), archive not listed exactly once in the signed SHA256SUMS (407) |
| AP-411 … 414 | the validated start: this Bitcoin Knots build does not know the snapshot's block (411); the file is not the expected snapshot, or Bitcoin Knots rejected its content (412: the file is deleted); the node did not load it (413); a Bitcoin Knots build that does not know the block of the snapshot a node still depends on is not put in place, or was put back because the node did not start on it (414) |
| AP-415 | networking could not be safely paused or confirmed restored after a validated start; any recovery marker and journal are kept. Fix the reported cause, then run `sudo alphapool-node repair`. The marker is `/etc/alphapool/network-paused`; do not delete it to bypass recovery |
| AP-416 | a snapshot import is still running, or its state could not be checked safely. This command refuses to continue without stopping the node, enabling networking or removing pending recovery state. Check `sudo alphapool-node status`; wait for the import to finish or fix the reported inspection problem, then run the same command again |
| AP-501 … 517 | install: apt, user, programs could not be put in place (503), gateway binary does not run (504), a config could not be written (505), node start, background service, firewall (ufw); upgrade put back: the new node did not start (511), the gateway did not come back (512), a service could not be stopped (515), the upgrade was cut off by a signal (516); upgrade done but the gateway is not back yet (513, exit code 3); an upgrade that was cut short was put back (517) |

AP-416 leaves the networking marker, validated-start journal, handed-off snapshot and installation/upgrade state
in place. It also leaves this invocation's scratch directory alone; the next run that passes the import guard
removes old `run.*` scratch directories when it prepares its work area. A failed RPC or service query is not proof
that an import has finished. A positively stopped or absent service can still follow the normal reboot/recovery path.

After AP-309 and AP-411 to AP-413 the node is stopped, so that it does not sync the whole chain by itself; the same
command goes on where it stopped, and `--sync network` chooses the full sync instead.

## Tested

- The whole test suite runs once per supported release (Ubuntu 24.04 and 22.04), in containers with no network.
- Every guard is also checked by a mutation test: the guard is broken on purpose, and its test must fail.
- The rule that root never works through the node user's folders is checked over the whole script by a test that
  fails when a new such operation appears.
- In the tests, the real Bitcoin Knots 29.4.2 is asked which snapshots it knows, and the real gateway programs are
  installed and run on both releases.
- The steps of the validated start were measured with the real Bitcoin Knots 29.4.2 and the real 9.6 GB snapshot on
  a machine sized like the 2 vCPU / 4 GB / 80 GB plan: block headers after about 3 minutes, the snapshot loaded
  after 13.5 minutes, then about 80 blocks a minute.
- Real installs and real in-place upgrades were run in such virtual machines with the version before this one
  (2026-10-07.2), including upgrades that were made to fail, killed in the middle, and cut off by a reset of the
  machine. These runs are repeated with each version before it is published.

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

### Watching after the installer hands over

Run `sudo alphapool-node status --watch` for one progress line each minute (blocks left, measured time left and peers), until READY shows the rig address. Ctrl-C stops watching; the node keeps working. If blocks stop advancing, the watch says so and does not keep showing an old estimate. The provider login screen updates every five minutes. Linux consoles show English only; SSH output and this guide retain Chinese.
