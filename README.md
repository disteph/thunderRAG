# ThunderRAG

**A privacy-first, LLM-powered email assistant for [Thunderbird](https://www.thunderbird.net/).**

ThunderRAG lets you search, triage, and draft replies to your email using natural language — powered by a local LLM, with your data never leaving your machine.

## What It Does

- **Natural-language search** — Ask questions like *"What did Mark say about the project deadline?"* and get answers grounded in your actual emails, with citations.
- **Automatic triage** — Each ingested email is scored for urgency and importance, with an estimated reply-by deadline.
- **Reply drafting** — Select one or more emails and let the LLM interview you with short yes/no questions, then produce a draft reply matching your writing style.
- **Processed tracking** — Mark emails as "dealt with" so you can focus on what's still pending.

All of this runs **locally**: Thunderbird remains the sole source of truth for your email content, and the LLM runs on your own hardware (or a server you control) via [Ollama](https://ollama.com/).

## Architecture

ThunderRAG has two components that work together:

```
┌───────────────────────┐         HTTP (localhost)         ┌──────────────────────┐
│  ThunderRAG  (add-on) │ ──────────────────────────────▸  │     RAG-o-Mail       │
│                       │  raw RFC822 emails, queries      │                      │
│  • Ingestion trigger  │ ◂──────────────────────────────  │  • MIME parsing      │
│  • Chat UI            │  answers, triage scores,         │  • LLM orchestration │
│  • Reply-draft UI     │  draft replies                   │  • Vector search     │
│  • Context menus      │                                  │  • Prompt management │
└───────────────────────┘                                  └──────┬───────────────┘
                                                                  │
                                                    ┌─────────────┼─────────────┐
                                                    │             │             │
                                                    ▼             ▼             ▼
                                                 Ollama      PostgreSQL    ~/.rag-o-mail/
                                               (local LLM)   + pgvector    (config, prompts)
```

### Why two components?

Thunderbird add-ons run in a sandboxed JavaScript environment with limited capabilities. The server handles everything that requires native libraries: MIME parsing, LLM API calls, vector embeddings, and database queries. Communication is strictly over `localhost` HTTP — no data leaves your machine.

**Key design principle:** The server never stores email bodies on disk. Thunderbird is the sole source of truth for email content. During queries, the add-on fetches full email text from Thunderbird on demand and uploads it as ephemeral evidence.

### Component overview

| Component | Location | Language | Description |
|---|---|---|---|
| **Thunderbird Add-on** | [`ThunderRAG/`](ThunderRAG/) | JavaScript | UI panels, context menus, ingestion triggers, Thunderbird API bridge |
| **RAG-o-Mail Server** | [`rag-o-mail/`](rag-o-mail/) | OCaml | HTTP server, LLM orchestration, vector search, email parsing. See the [server README](rag-o-mail/README.md) for endpoints, configuration, and module structure. |

## Requirements

- **[Thunderbird](https://www.thunderbird.net/)** 140 or later
- **[Ollama](https://ollama.com/)** — local LLM runtime (provides both chat and embedding models)
- **[PostgreSQL](https://www.postgresql.org/)** 14+ with the **[pgvector](https://github.com/pgvector/pgvector)** extension
- **[OCaml](https://ocaml.org/)** 5.x with [opam](https://opam.ocaml.org/) (to build the server)
- **[libpg_query](https://github.com/pganalyze/libpg_query)** (used to validate LLM-generated SQL fragments)

**Optional (voice features):**

- **[Whisper.cpp](https://github.com/ggerganov/whisper.cpp)** — local speech-to-text server
- **[Piper](https://github.com/rhasspy/piper)** — local text-to-speech CLI
- **[SoX](https://sox.sourceforge.net/)** — audio recording utility (`rec` command for server-side mic capture)

## Installation

### 1. Install system dependencies

<details>
<summary><strong>macOS (Homebrew)</strong></summary>

```bash
brew install postgresql@17 pgvector libpg_query ollama opam
brew services start postgresql@17

# Optional: voice features (STT / TTS)
brew install sox whisper-cpp
brew install pipx && pipx install piper-tts
pipx inject piper-tts pathvalidate   # fix missing dependency
```

**Apple Silicon note:** Homebrew on ARM installs PostgreSQL outside the default compiler/linker search paths. Add all three lines to your `~/.zshrc` **before** building the OCaml dependencies:

```bash
export LIBRARY_PATH="/opt/homebrew/lib/postgresql@17:$LIBRARY_PATH"
export C_INCLUDE_PATH="/opt/homebrew/include/postgresql@17:$C_INCLUDE_PATH"
export PKG_CONFIG_PATH="/opt/homebrew/lib/postgresql@17/pkgconfig:$PKG_CONFIG_PATH"
```

- `LIBRARY_PATH` — lets the linker find `libpq.dylib` when linking the final binary.
- `C_INCLUDE_PATH` — lets the C compiler find `libpq-fe.h` when building the `postgresql` opam package stubs.
- `PKG_CONFIG_PATH` — lets the `postgresql` opam package's build-time discovery script (`pkg-config libpq`) record the correct `-L` flag. **Without this, stubs compile but the final link fails with "symbol(s) not found for architecture arm64".** If you already installed the `postgresql` opam package without this variable, run `opam reinstall postgresql` after setting it.

</details>

<details>
<summary><strong>Ubuntu / Debian</strong></summary>

```bash
# PostgreSQL + pgvector
sudo apt install postgresql postgresql-17-pgvector libpq-dev

# libpg_query (build from source)
sudo apt install build-essential
git clone https://github.com/pganalyze/libpg_query.git
cd libpg_query && make && sudo make install && sudo ldconfig
cd .. && rm -rf libpg_query

# OCaml toolchain
sudo apt install opam
opam init -y          # first time only
eval $(opam env)

# Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Optional: voice features (STT / TTS)
sudo apt install sox
# Whisper.cpp: build from source — https://github.com/ggerganov/whisper.cpp#build
# Piper: download prebuilt binary — https://github.com/rhasspy/piper/releases
```

</details>

<details>
<summary><strong>Fedora / RHEL</strong></summary>

```bash
sudo dnf install postgresql-server libpq-devel gcc make
sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql

# pgvector (build from source)
git clone --branch v0.8.0 https://github.com/pgvector/pgvector.git
cd pgvector && make && sudo make install
cd .. && rm -rf pgvector

# libpg_query (build from source)
git clone https://github.com/pganalyze/libpg_query.git
cd libpg_query && make && sudo make install && sudo ldconfig
cd .. && rm -rf libpg_query

# OCaml toolchain
sudo dnf install opam
opam init -y          # first time only
eval $(opam env)

# Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Optional: voice features (STT / TTS)
sudo dnf install sox
# Whisper.cpp: build from source — https://github.com/ggerganov/whisper.cpp#build
# Piper: download prebuilt binary — https://github.com/rhasspy/piper/releases
```

</details>

<details>
<summary><strong>Windows (WSL2)</strong></summary>

Install [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install) with an Ubuntu distribution, then follow the Ubuntu instructions above inside WSL.

**Key points:**

- **Thunderbird** runs natively on Windows. Modern WSL2 automatically forwards `localhost` ports, so the add-on connects to the server at `http://localhost:8080` as usual.
- **PostgreSQL**: start it inside WSL with `sudo service postgresql start` (WSL doesn't use systemd by default).
- **Ollama**: install on Windows natively (not inside WSL) for GPU access, or inside WSL if using CPU only. Both expose `localhost:11434`.
- **Voice features**: `sox`/`rec` require PulseAudio forwarding from WSL to Windows for mic access. This is non-trivial; voice features may not work out of the box on WSL2.

</details>

### 2. Set up the database

```bash
createdb rag-o-mail
psql -d rag-o-mail -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

Or use `make setup-db` from the repository root.

### 3. Set up voice models (optional)

If you want speech-to-text (STT) and text-to-speech (TTS):

```bash
# Download a Whisper model (base.en is a good default, ~141 MB)
mkdir -p ~/.local/share/whisper
wget -O ~/.local/share/whisper/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin

# Download a Piper voice model
mkdir -p ~/.local/share/piper
wget -O ~/.local/share/piper/en_US-lessac-medium.onnx \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx
wget -O ~/.local/share/piper/en_US-lessac-medium.onnx.json \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json
```

Configure the paths in the add-on's Preferences → Voice section (server settings), or edit `~/.rag-o-mail/settings.json` directly:

```json
"voice": {
  "piper_model": "~/.local/share/piper/en_US-lessac-medium.onnx",
  "piper_bin": "piper",
  "whisper_url": "http://localhost:8178"
}
```

Start the Whisper server before using STT:

```bash
whisper-server --model ~/.local/share/whisper/ggml-base.en.bin --port 8178
```

### 4. Pull Ollama models

```bash
ollama pull nomic-embed-text    # embedding model (required)
ollama pull llama3              # chat model (or any model you prefer)
```

### 5. Build the server

```bash
# Install OCaml toolchain (first time only)
# If you haven't already: install opam (see platform instructions above)
opam init -y              # first time only (skip if already done)
eval $(opam env)
cd rag-o-mail
opam switch create . ocaml-base-compiler.5.2.0
opam install . --deps-only -y

# Build
dune build
```

Or from the repository root: `make ocaml`

See the [server README](rag-o-mail/README.md) for the full list of configuration options, environment variables, and HTTP endpoints.

### 6. Install the Thunderbird add-on

```bash
make xpi    # produces ThunderRAG/dist/thunderRAG.xpi
```

Then in Thunderbird:

1. **Tools → Add-ons and Themes** (or `Ctrl+Shift+A`)
2. Click the gear icon → **Install Add-on From File…**
3. Select `ThunderRAG/dist/thunderRAG.xpi`

### 7. Configure the add-on

Open the add-on's **Preferences** page (Add-ons → ThunderRAG → Preferences):

- **RAG-o-Mail URL** — The address of the RAG-o-Mail server (default: `http://localhost:8080`)
- **Who Am I** — Your name, email, and/or role, used to personalize triage and reply drafting
- **Top-K** — How many emails to retrieve per query (default: 20)

## Usage

### Start the server

```bash
cd rag-o-mail
dune exec -- rag-o-mail -p 8080
```

Or from the repository root: `make run` (uses port 8080 by default).

The server creates the database schema automatically on first startup.

**Optional — start the voice server** (if you set up voice models above):

```bash
# In a separate terminal:
whisper-server --model ~/.local/share/whisper/ggml-base.en.bin --port 8178
python3 scripts/voice-server.py --port 8179
```

### Ingest emails

Right-click one or more emails in Thunderbird → **ThunderRAG: Ingest selected emails**. The add-on sends the raw email to the server, which parses it, generates triage scores, creates vector embeddings, and stores everything in PostgreSQL.

Ingested emails show a status indicator (●) in the message list. You can also set up Thunderbird **message filters** to ingest emails automatically as they arrive.

### Ask questions

Click the **ThunderRAG** toolbar button to open the chat panel. Type a question in natural language. The system:

1. Rewrites your question for optimal retrieval (resolving pronouns, dates, references)
2. Searches the vector index for relevant emails
3. Asks Thunderbird to fetch the full text of matching emails
4. Sends everything to the LLM with your question
5. Returns a grounded answer with `[Email N]` citations you can click to jump to the original

### Draft replies

Right-click an email → **ThunderRAG: Draft reply**. The LLM reads the email, retrieves your previous correspondence with that sender for tone matching, and interviews you with short questions. Once it has enough information, it produces a complete draft reply that you can edit, save as a Thunderbird draft, or send directly.

### Track processed emails

Right-click an ingested email → **Mark as processed** to flag it as handled. When you ask the assistant about pending tasks or action items, processed emails are automatically excluded.

## Privacy and Security

- **All processing is local.** Emails are sent only to `localhost` — never to any external service.
- **Email bodies are not stored on disk** by the server. Only metadata (headers, triage scores, timestamps) and vector embeddings are persisted. Full email text lives exclusively in Thunderbird.
- **The LLM runs on your hardware** via Ollama. You choose which model to use and where it runs.
- **No telemetry, no analytics, no cloud dependency.**

## Project Structure

```
ThunderRAG/
├── ThunderRAG/                  # Thunderbird add-on
│   ├── manifest.json            # Add-on manifest (permissions, experiment APIs)
│   ├── background.js            # Event handlers, ingestion pipeline, menu actions
│   ├── ui/
│   │   ├── query.html/.js       # Chat panel (natural-language Q&A)
│   │   ├── reply.html/.js       # Reply-drafting panel (LLM interview + draft editor)
│   │   ├── options.html/.js     # Add-on preferences (server URL, identity)
│   │   └── ingested-detail.*    # Ingestion detail viewer
│   └── experiments/             # Thunderbird Experiment API (filter action)
├── rag-o-mail/                  # RAG-o-Mail server
│   ├── bin/main.ml              # HTTP server, LLM integration, ingestion + query pipelines
│   ├── lib/                     # Libraries (PostgreSQL, MIME parsing, text processing, SQL validation)
│   ├── prompts.json             # All LLM prompts (customizable via ~/.rag-o-mail/prompts.json)
│   └── README.md                # Detailed server documentation
├── Makefile                     # Top-level build targets
└── README.md                    # This file
```

## Build Targets

| Command | Description |
|---|---|
| `make all` | Build both the add-on XPI and the OCaml server |
| `make xpi` | Build the add-on XPI (`ThunderRAG/dist/thunderRAG.xpi`) |
| `make ocaml` | Install OCaml dependencies and build the server |
| `make setup-db` | Create the `rag-o-mail` database and enable pgvector |
| `make run` | Build and run the server on `http://127.0.0.1:8080` |
| `make clean` | Clean all build artifacts |

## License

[MIT](LICENSE)
