# Agent notes — implementation

Language-specific build and verification for the Prop implementation
(`10_impl/agent_prop/`). Repo-wide workflow lives in the root
[`README.md`](../README.md).

## Build and verify

Run Dart from `10_impl/agent_prop` so mise picks 3.13.5 (Dart 3.11 elsewhere
rejects the package language version). The Dart package is `sudoer_prop`.
`PUB_CACHE` is the repo-root `.pub-cache/` — `mise.toml` sets it via `[env]`,
so `mise` tasks are machine-independent; export it yourself when calling
`dart` directly.

```
dart analyze
dart test          # offline; ScriptedProvider / SUDOER_SCRIPT_FILE
mise run gate      # 24 tasks + smoke, no LLM (POSIX-shell tasks SKIP on Windows)
mise run build     # compile into 90_dist/sudoer-prop-<v>-<os>-<arch>/ and re-point the 10_impl + 20_eval symlinks
```

## Secrets

The live config `20_eval/agent_prop/sudoer.json` (with its `api_key`) is
git-ignored; only the sops/age-encrypted
`20_eval/agent_prop/sudoer.enc.json` is tracked. Decrypt with
`sops --decrypt` before running; never commit the plaintext or the age private
key (`~/.config/sops/age/keys.txt`).
