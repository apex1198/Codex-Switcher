# Codex API Switcher for macOS

Native macOS utility for switching Codex seamlessly between multiple AI providers while securely managing API keys in macOS Keychain.

![App icon](Assets/AppIcon-1024.png)

## Supported Providers

1. **OpenAI / ChatGPT (Subscription)**: Uses your existing account-based ChatGPT/Codex login session (no API key required).
2. **Model API**: `https://modelapi.vn/v1` with Responses API and `requires_openai_auth = true` (recommended model: `gpt-5.6-sol`).
3. **AIOffer API**: `https://api.aioffer.tech/v1` with Responses API and cockpit tools headers (recommended model: `gpt-6-astra`).
4. **TTM API**: `https://ttmapi.site/v1` with Responses API and cockpit tools headers (recommended model: `gpt-5.6-luna`).
5. **OpenAI API**: Direct `https://api.openai.com/v1` using your own OpenAI API key.

## Features

- **Unified Switcher**: Select between all providers with a single click.
- **Model Selector**: Auto-fills recommended models for each provider (`gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-luna`) while allowing custom input.
- **Keychain Security**: All API keys are stored securely in macOS Keychain; no raw secrets are written to configuration files.
- **Credential Preservation**: Existing ChatGPT OAuth credentials in `~/.codex/auth.json` and existing keys in `~/.codex/ttm-api-keys.json` are preserved.
- **Fast Profile Reset**: Automatically updates `~/.codex/config.toml` and allows launching Codex for an instant new task.
- Native dark AppKit interface; zero external runtime dependencies.

## Requirements

- macOS 13 or later.
- Codex CLI or Codex desktop app.
- Xcode Command Line Tools for building from source.

## Build

```bash
# Build the main Codex API Switcher (and update /Applications if present)
./build.sh switcher

# Or build all app variants (Codex API Switcher, ChatGPT API, ChatGPT Subscription)
./build.sh all
```

The resulting apps are placed in `build/` (e.g. `build/Codex API Switcher.app`).

## Usage

1. Open **Codex API Switcher**.
2. If using an API provider (Model API, AIOffer, TTM, OpenAI API), click **+ Thêm API key…** to store your key in Keychain.
3. Select your desired **Provider**, verify or adjust the **Codex Model**, and pick your active key.
4. Click **Save • Reset & Task mới**.
5. Open Codex and click **New Task** to run with the new provider!

## Disclaimer

This is an independent utility and is not an official OpenAI product. Codex and OpenAI are trademarks of OpenAI. Third-party APIs (AIOffer, Model API, TTM) are independent services.
