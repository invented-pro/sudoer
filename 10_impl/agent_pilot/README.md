# sudoer_pilot

The Pilot agent — the personal-assistant tier (C1–C11), a superset of
Prop, built by the **Prop agent** against the blueprint in
[`00_bp/agent_pilot.md`](../../00_bp/agent_pilot.md).

This folder is the **prop + blueprint driven evolvement** unit:

| Path | What |
| --- | --- |
| [`pilot-build.json`](pilot-build.json) | live LLM config for the builder (git-ignored; carries the endpoint key) |
| [`pilot-build.enc.json`](pilot-build.enc.json) | sops/age-encrypted `pilot-build.json` (tracked) |
| [`pilot-build-example.json`](pilot-build-example.json) | template with a placeholder key (tracked) |
| [`startup.sh`](startup.sh) | the button — starts the published Prop binary on a Pilot goal |
| [`generated/`](generated/) | everything Prop writes: the Dart package (pubspec, `lib/`, `bin/`, `test/`, `tool/`) |
| [`AGENTS.md`](AGENTS.md) | the build contract the builder follows |

Nothing outside `generated/` is machine-written. See
[AGENTS.md](AGENTS.md) for the toolchain; run it from `generated/`:

```sh
cd generated
dart pub get
dart analyze
dart test
```

## Config / secrets

The live config `pilot-build.json` (with its `api_key`) is git-ignored; only
the sops/age-encrypted `pilot-build.enc.json` is tracked. Decrypt it before
running the button, and never commit the plaintext or the age private key
(`~/.config/sops/age/keys.txt`):

```sh
sops --decrypt pilot-build.enc.json > pilot-build.json   # once per checkout
./startup.sh
```

To rotate or change the key, copy `pilot-build-example.json` to
`pilot-build.json`, edit it, then write the encrypted form back:

```sh
sops --encrypt --input-type json --output-type json \
  pilot-build.json > pilot-build.enc.json
```


Status: building — Milestones 1–3 green (chain/store/log, memory,
safety, reminders, Pilot tools, interface commands); serve API, gate
harness, and the build script remain.
