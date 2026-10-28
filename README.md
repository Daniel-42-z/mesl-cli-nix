# MESL CLI for NixOS

Packages MESL CLI, the upstream bundled Mihomo core, and `geoip.metadb` for `x86_64-linux` and `aarch64-linux`. The NixOS module runs one root-owned instance and installs `mesl-cli` on the system command path.

## NixOS configuration

Add this repository as a flake input in `flake.nix` (replace the example URL with your checkout or hosted repository). Pass the flake inputs to your NixOS modules through `specialArgs`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    mesl = {
      url = "path:/home/daniel/Projects/mesl-cli-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ nixpkgs, ... }: {
    nixosConfigurations.myHost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        ./configuration.nix
        ./mesl.nix
      ];
    };
  };
}
```

Create `mesl.nix` alongside `flake.nix` to import and configure the MESL module:

```nix
{ inputs, lib, ... }:
{
  imports = [ inputs.mesl.nixosModules.mesl ];

  nixpkgs.config.allowUnfreePredicate =
    pkg: lib.getName pkg == "mesl-cli";

  services.mesl = {
    enable = true;
    autoStart = false;
    tun.enable = false;
  };
}
```

Merge the unfree predicate with your existing policy if you already permit other unfree packages. The MESL client distribution does not include an explicit license grant, so this package is conservatively marked unfree.

| Option                     | Default                   | Meaning                                                    |
| -------------------------- | ------------------------- | ---------------------------------------------------------- |
| `services.mesl.enable`     | `false`                   | Install the command and define `mesl.service`              |
| `services.mesl.package`    | This repository's package | Override the client package                                |
| `services.mesl.autoStart`  | `false`                   | Start at boot                                              |
| `services.mesl.tun.enable` | `false`                   | Run with `--tun`, load `tun`, and permit TUN device access |

## Authentication and service management

After rebuilding NixOS, authenticate interactively before starting the service:

```sh
sudo mesl-cli login
sudo systemctl start mesl
sudo mesl-cli status
sudo mesl-cli node list
sudo mesl-cli node auto
sudo mesl-cli mode global
sudo journalctl -u mesl -f
sudo systemctl stop mesl
```

The module's command defaults to `/var/lib/mesl`, shared with the service. Run administrative commands with `sudo`: the state directory is root-owned with mode `0700`, and new service files use mode `0600`. Credentials are created at runtime and never embedded in Nix expressions or the Nix store. Existing state under `/etc/mesl` or `~/.config/mesl` is not migrated automatically. An explicit `--data-dir` or `MESL_DATA_DIR` overrides the command's default; the service always passes `/var/lib/mesl` explicitly.

Use `systemctl start/stop/restart mesl` for the managed daemon rather than `mesl-cli up/down/daemon`. Do not start a second instance using the same ports. Use `systemctl stop mesl` before `sudo mesl-cli logout` if autostart is enabled.

Set `autoStart = true` after login to start at boot. Without valid credentials the service fails and retries every five seconds; inspect the journal to diagnose it. Turning autostart off removes the boot dependency; use `systemctl stop mesl` to stop an already running instance.

For machine-wide TUN routing, set `tun.enable = true` and rebuild. Both modes use a root system service. TUN mode gives the bundled core access to `/dev/net/tun` and host routing; it does not use a network namespace. Stopping the daemon lets MESL and Mihomo clean up their runtime state and routes.

## Ports and desktop proxy settings

MESL 2.0.3 hardcodes these local listeners:

| Listener                 | Address          |
| ------------------------ | ---------------- |
| Mixed HTTP/SOCKS proxy   | `127.0.0.1:7688` |
| Authenticated controller | `127.0.0.1:9688` |
| DNS                      | `127.0.0.1:1053` |

There is no configurable port option in this module yet. Ports are not forwarded, and firewall ports are not opened. Port conflicts must be resolved before starting the service.

The system service passes `--no-proxy` so it does not attempt to change a GNOME session's proxy settings. Without TUN, configure applications manually, for example:

```sh
export http_proxy=http://127.0.0.1:7688
export https_proxy=http://127.0.0.1:7688
export all_proxy=socks5h://127.0.0.1:7688
```

The service preserves MESL's persisted mode and node selection. MESL's own encrypted state, runtime configuration, and login verification behavior remain managed by the upstream client. See the packaged upstream README under `share/doc/mesl-cli/README.md` for commands and details.

## Standalone package

From this checkout:

```sh
nix build .#mesl-cli
nix run . -- version
nix run . -- login
```

The flake's package outputs permit this specific unfree package. Importing `package.nix` directly uses your own Nixpkgs unfree policy. The standalone command retains upstream state defaults (`~/.config/mesl` for normal users and `/etc/mesl` for root); only the NixOS module defaults to `/var/lib/mesl`.

The package keeps the real CLI, core, and geodata together under `libexec/mesl`. Its command wrapper defaults `MESL_CORE` to the bundled executable; an explicit core argument or environment setting can override it. No files from the original local installation are required at runtime.

## Development and updates

```sh
nix flake check
nix build .#checks.x86_64-linux.service
nix build .#checks.aarch64-linux.package
```

The VM check needs a working NixOS test VM backend; native architecture builders or configured emulation are needed to execute checks for another architecture. Package checks run the real CLI's help/version and validate a minimal direct-only configuration with the bundled core. Module evaluation checks cover disabled, manual, autostart, and TUN settings. The VM uses a stub client, exercises restart and graceful shutdown, verifies state permissions, and creates a real TUN device. It does not authenticate with MESL or test subscription-based routing.

For a real-account acceptance check:

- Log in, start the service, and confirm `sudo mesl-cli status` reports running.
- Test HTTP and SOCKS traffic through `127.0.0.1:7688`.
- Enable TUN, rebuild, and verify ordinary application traffic and DNS follow the intended routes without proxy environment variables.
- Enable autostart, reboot, and confirm the daemon starts using persisted state.
- Stop the service and verify the core exits and TUN routes/devices are removed.

Release metadata lives in `release.json`. To check or update it locally:

```sh
nix run .#update -- --check
nix run .#update -- --write
```

Run these commands from the repository, or pass `--repo /path/to/checkout`. Check mode reports JSON without changing files. Write mode replaces metadata atomically only after both archives pass size, hash, archive-path, required-file, and ELF architecture checks. Downloads are never executed by the updater. Package smoke checks require the packaged CLI's exact advertised version.

The updater queries `https://dl-zone1.rlose.com/version/mesl.json`, falling back to `https://version.meslapp.com/version.json`, with MESL's documented User-Agent. Only newer stable `MAJOR.MINOR.PATCH` versions are accepted. Unchanged versions are a no-op; downgrades are ignored. A same-version checksum or size replacement fails for manual investigation. Missing architectures, invalid manifests, and download failures leave existing pins intact. Upstream URLs may be mutable even with version query parameters; fixed hashes enforce integrity but do not preserve historical download availability.

Update Nixpkgs separately using `nix flake lock --update-input nixpkgs`. Use Jujutsu for repository operations; for example, `jj --no-pager status` and `jj --no-pager diff`.

## Autonomous GitHub updates

The public repository's update workflow runs daily at **03:37 UTC** and supports manual dispatch. It uses only the repository's `GITHUB_TOKEN`: no GitHub App, personal access token, or additional secret is required.

The workflow prepares a local Jujutsu candidate from the current default branch and archives its source and VCS identity. Shared validation runs native AMD64 and ARM64 builds and smoke checks, module evaluation, updater/publication tests, formatting, workflow and shell linting, and fresh AMD64 service VMs. The VM suite requires KVM and uses the existing stub client; account login and subscription routing are not tested. VM diagnostics and validation evidence are retained for 14 days.

Only the publication job has write permissions. It requires matching success records for the exact candidate commit, parent, and source digest. It checks for concurrent default-branch or update-branch changes, pushes with Jujutsu's remote reference safety checks, and verifies the resulting remote heads. It then creates or refreshes the `mesl-update` PR, attaches the `mesl-update/validated` status to the tested commit, and requests squash auto-merge matching that exact head. Validation failures do not publish candidates. If a branch moves, the next daily or manual run prepares and validates against the new parent.

Validation occurs inside the scheduled workflow, rather than relying on another workflow triggered by the bot PR. Ordinary push and PR checks use the same validation workflow. Upstream release data and candidate binaries are processed only in jobs without repository write permissions; publication does not execute the downloaded client. The committed release metadata is the only file a release candidate may change.

Configure these settings once after publishing the repository:

- Under **Actions → General → Workflow permissions**, allow GitHub Actions to create pull requests. Organization settings must permit it too.
- Under **General → Pull Requests**, enable **Allow auto-merge** and **Allow squash merging**.
- Protect the default branch with the required `mesl-update/validated` status and **Require branches to be up to date before merging**. Do not require a separate bot-PR workflow that cannot run unattended with `GITHUB_TOKEN`.
- Do not require human approval for the automation PRs if fully autonomous merging is desired. The workflow respects branch protection and does not bypass it.
- Keep Actions enabled, and use manual dispatch to verify initial setup. GitHub publication, required-status behavior, and actual auto-merge need a hosted run to verify; local publication tests mock the GitHub API.

### Heartbeat maintenance

GitHub disables public-repository scheduled workflows after **60 days without repository activity**. Daily polling alone is not the activity this design relies on. After 30 days without a new default-branch commit, the updater prepares a `mesl-heartbeat` PR changing only `.github/update-heartbeat.json` to record the current UTC time. Its lightweight validation verifies the candidate identity, timestamp, and that no package or workflow files changed. It uses the same required-status and exact-head auto-merge gate as release updates, without downloading or executing upstream binaries again.

A successful heartbeat merge creates a real default-branch commit and restarts the inactivity period, providing roughly 30 days of margin before GitHub's 60-day cutoff. Release merges and ordinary development commits postpone the next heartbeat. Heartbeat preparation remains available when MESL discovery fails; the workflow still reports that discovery failure after attempting maintenance.

This depends on the workflow continuing to run and maintenance merges succeeding. Disabled Actions, exhausted runner capacity, authentication failures, or changed branch rules can prevent it; once GitHub disables execution, this workflow cannot reactivate itself. Resolve the cause and manually re-enable/dispatch the updater.
