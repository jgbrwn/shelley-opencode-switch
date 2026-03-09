# shelley-opencode-switch

A Bash controller script for switching an [exe.dev](https://exe.dev) VM between [Shelley](https://github.com/boldsoftware/shelley) and [OpenCode](https://opencode.ai) on the same port.

---

# Purpose

This script supports a workflow where:

- `shelley` normally runs on port `9999`
- when exe.dev credits are exhausted, you temporarily stop `shelley`
- you start the `opencode` Web UI on the same port
- you bootstrap an **OpenCode session using the latest Shelley conversation** for that project
- when finished, you switch back to Shelley

The goal is a **clean transition between Shelley and OpenCode** without losing project context.

---

# Architecture

```
Shelley
   │
   │ (extract latest conversation from SQLite)
   ▼
.codex-handoff/
   │
   │ Stage 1: CLI Bootstrap (--yolo)
   ▼
OpenCode Agent (Synchronous)
   │
   │ Stage 2: Web UI
   ▼
OpenCode Serve (Port 9999)
```

Explanation:

1. The script extracts the **latest Shelley conversation tied to the project directory**
2. It generates **handoff files inside the repository**
3. It launches **OpenCode CLI with --yolo** to absorb the context synchronously
4. It starts the **OpenCode Web UI** on the shared port

This allows work to continue in OpenCode with **minimal context loss**.

---

# Features

- **Auto-Installation**: Installs `opencode` via `curl -fsSL https://opencode.ai/install | bash` if not found in PATH.
- **Service Management**: Stops `shelley` **and `shelley.socket`** to free port `9999`.
- **YOLO Capability**: Uses the `--yolo` flag during bootstrap so the agent has full permissions to understand the repository.
- **Regular User Execution**: Runs opencode as the **regular user**, only using `sudo` for `systemctl`.
- **Port Verification**: Verifies port `9999` is free before starting the Web UI.
- **Context Awareness**: Reads the Shelley SQLite DB for the **latest conversation tied to the project directory**.
- **Idempotency**: Avoids repeating bootstrap unless `--force-bootstrap` is used.

---

# Files created in each project

When bootstrap runs, the script creates a project-local directory:

```
.codex-handoff/
```

Containing:

```
.codex-handoff/
 ├─ shelley-bootstrap.md
 ├─ shelley-bootstrap.jsonl
 ├─ bootstrap-prompt.txt
 └─ opencode-bootstrap.done
```

### shelley-bootstrap.md

Human-readable reconstruction of the Shelley conversation.

### shelley-bootstrap.jsonl

Raw extracted messages from the Shelley database.

### bootstrap-prompt.txt

The prompt used to initialize the OpenCode session.

### opencode-bootstrap.done

Marker file preventing duplicate bootstrap.

---

# Usage

## Start OpenCode and bootstrap from Shelley

```bash
./shelley-opencode-switch.sh \
  -start \
  --project-dir /path/to/repo \
  --shelley-db /path/to/shelley.db
```

---

## Start without bootstrap

```bash
./shelley-opencode-switch.sh -start --shelley-db /dev/null
```

---

## Force a fresh bootstrap

```bash
./shelley-opencode-switch.sh \
  -start \
  --project-dir /path/to/repo \
  --shelley-db /path/to/shelley.db \
  --force-bootstrap
```

---

## Return to Shelley

```bash
./shelley-opencode-switch.sh -stop
```

---

# Requirements

- bash
- sudo
- systemctl
- sqlite3
- python3
- jq
- curl
- lsof (for port checks)

---

# Notes

- The systemd service name must be **`shelley`**
- The script stops/starts **both `shelley` and `shelley.socket`**
- OpenCode logs and PID files live in:

```
~/.cache/shelley-opencode-switch/
```
- The shared port is:

```
9999
```
