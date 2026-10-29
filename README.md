# MESL CLI for NixOS

Packages MESL CLI, the upstream bundled Mihomo core, and `geoip.metadb` for `x86_64-linux` and `aarch64-linux`. The NixOS module installs `mesl-cli` on the system command path and runs one instance, either as a configured user or as root.

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
    user = "yourusername";
    autoStart = false;
    tun.enable = true;
  };
}
```

Replace `yourusername` with an existing normal NixOS user declared in your configuration. User mode uses that account's existing `~/.config/mesl` profile and supports TUN without sudo. NixOS manages the capability wrapper and user service, so a separate Home Manager module is unnecessary.

Merge the unfree predicate with your existing policy if you already permit other unfree packages. The MESL client distribution does not include an explicit license grant, so this package is conservatively marked unfree.

| Option                     | Default                   | Meaning                                                    |
| -------------------------- | ------------------------- | ---------------------------------------------------------- |
| `services.mesl.enable`     | `false`                   | Install the command and define `mesl.service`              |
| `services.mesl.package`    | This repository's package | Override the client package                                |
| `services.mesl.user`       | `null`                    | Existing normal user; `null` keeps the root system service |
| `services.mesl.autoStart`  | `false`                   | Start at boot                                              |
| `services.mesl.tun.enable` | `false`                   | Run with `--tun`, load `tun`, and permit TUN device access |

## Authentication and service management

After rebuilding NixOS with `user = "yourusername"`, run commands as that user. When first enabling user-mode TUN, reboot once to refresh both your login session's and your systemd user manager's membership in the `mesl` group. Existing login credentials in `~/.config/mesl` are reused; otherwise authenticate before starting the service:

```sh
mesl-cli login
systemctl --user start mesl
mesl-cli status
mesl-cli node list
mesl-cli node auto
mesl-cli mode global
journalctl --user -u mesl -f
systemctl --user stop mesl
```

The user service passes `--data-dir %h/.config/mesl`; ordinary CLI commands retain upstream's user-profile default. An explicit CLI `--data-dir` or `MESL_DATA_DIR` can select another profile, but the managed service continues to use `~/.config/mesl`. The service uses `UMask=0077`, and credentials are created at runtime rather than embedded in the Nix store.

Use `systemctl --user start/stop/restart mesl` for the managed daemon. If you prefer manual operation, leave the service stopped and run `mesl-cli up --tun`, followed by `mesl-cli down` when finished. Do not start both instances at once: they share state and fixed ports. Stop the managed service before `mesl-cli logout`.

Set `autoStart = true` after login to start at boot. In user mode the module enables NixOS-managed lingering for the selected account, so its user manager and MESL start without an interactive login. The unit only runs for that account. Your home directory must be available at boot; otherwise start the service after unlocking or mounting it. Without valid credentials the service fails and retries every five seconds. Turning autostart off removes the service's startup dependency; stop an already running instance explicitly. It does not forcibly disable lingering configured elsewhere.

With user-mode TUN enabled, NixOS creates `/run/wrappers/bin/mesl-client` and `/run/wrappers/bin/mesl-mihomo` with `cap_net_admin+ep`, owned by root and executable only by root and the `mesl` group. The configured user is added to that group. The module's CLI launcher runs MESL through the client wrapper and points `MESL_CORE` at the core wrapper, so manual commands and the service use the same capabilities. Both processes run as your user with permission to administer host networking. MESL needs the matching capability to inspect Mihomo's socket descriptors under `/proc` when verifying controller ownership; granting it only to Mihomo causes misleading controller-port conflicts. Their source and binaries are unchanged. The service permits acquiring these file capabilities by leaving `NoNewPrivileges` disabled in this mode. Disabling TUN removes both wrappers and the module's group-membership grant.

TUN affects host routing and uses `/dev/net/tun`; it does not use a network namespace. Stopping the daemon lets MESL and Mihomo clean up their runtime state and routes.

### Root mode and switching modes

Leaving `services.mesl.user = null` preserves the root system service and `/var/lib/mesl` profile. Use `sudo mesl-cli login`, `sudo mesl-cli status`, and `sudo systemctl start/stop/restart mesl` in that mode. Its command defaults to `/var/lib/mesl`; an explicit CLI data directory or environment setting can override it. Root mode does not install the capability wrapper.

Before switching modes, stop the old service (`sudo systemctl stop mesl` for root mode, or `systemctl --user stop mesl` for user mode). Rebuild and then start the new service. Existing root-owned state is left intact; no profiles are moved or ownership changed automatically. Root mode does not automatically use `~/.config/mesl`, and user mode does not automatically import `/var/lib/mesl` or `/etc/mesl`.

## Ports and desktop proxy settings

MESL 2.0.3 hardcodes these local listeners:

| Listener                 | Address          |
| ------------------------ | ---------------- |
| Mixed HTTP/SOCKS proxy   | `127.0.0.1:7688` |
| Authenticated controller | `127.0.0.1:9688` |
| DNS                      | `127.0.0.1:1053` |

There is no configurable port option in this module yet. Ports are not forwarded, and firewall ports are not opened. Port conflicts must be resolved before starting the service.

The managed service passes `--no-proxy` so it does not attempt to change a GNOME session's proxy settings. Without TUN, configure applications manually, for example:

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

The flake's package outputs permit this specific unfree package. Importing `package.nix` directly uses your own Nixpkgs unfree policy. The standalone command retains upstream state defaults (`~/.config/mesl` for normal users and `/etc/mesl` for root); the NixOS module's root mode defaults to `/var/lib/mesl`. The standalone package does not create privileged wrappers; use the module-installed command for user-mode TUN.

The package keeps the real CLI, core, and geodata together under `libexec/mesl`. Its command wrapper defaults `MESL_CORE` to the bundled executable; an explicit core argument or environment setting can override it. No files from the original local installation are required at runtime.

## Development and updates

```sh
nix flake check
nix build .#checks.x86_64-linux.service
nix build .#checks.x86_64-linux.user-service
nix build .#checks.aarch64-linux.package
```

The VM checks need a working NixOS test VM backend; native architecture builders or configured emulation are needed to execute checks for another architecture. Package checks run the real CLI's help/version and validate a minimal direct-only configuration with the bundled core. Module evaluation checks cover disabled, manual, autostart, and TUN settings. The root-service VM uses a stub client, exercises restart and graceful shutdown, verifies state permissions, and creates a real TUN device. The user-service VM checks TUN creation, controller socket inspection, manual startup, and wrapper access restrictions, including a regression check that fails with capabilities granted only to the core. Neither VM authenticates with MESL or tests subscription-based routing.

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

## Optional internet kill switch

The NixOS module provides an opt-in host-wide guard:

```nix
services.mesl = {
  enable = true;
  user = "yourusername"; # Omit for the root service.
  autoStart = true;
  tun.enable = true;
  killSwitch.enable = true;
  # killSwitch.interface = "Meta"; # Must match the actual TUN name.
};
```

It is disabled by default. When enabled, applications can reach the internet
through MESL's TUN, and MESL itself can make direct connections according to its
routing rules. Other processes, including those belonging to the same user,
cannot connect directly to public internet addresses. IPv4, IPv6, and forwarded
container traffic are covered. Existing direct connections are also blocked.
Loopback, private/link-local LAN destinations, DHCP, and IPv6 neighbor discovery
remain available. LAN DNS remains available; public DNS must pass through MESL.
The guard does not grant a general bypass to systemd-resolved: configure MESL's
bootstrap resolver to use LAN DNS or connections made by MESL itself if needed.

With autostart enabled the guard arms before network-pre.target. Otherwise it
arms on the first managed service start. A failed start, crash, normal unexpected
exit, service restart, or ordinary `systemctl stop` leaves it armed. The service
retries unexpected exits every five seconds. A tunnel or proxy outage therefore
cannot silently enable direct host internet access.

Use these privileged commands for deliberate control:

```sh
sudo mesl-guard start
sudo mesl-guard status
sudo mesl-guard stop
```

`stop` stops the configured service and checks that its processes have exited
before removing protection. It also works after a crash. `start` arms protection
before starting the configured root or user service. Starting the service with
systemctl also arms protection, but stopping it with systemctl does not release
protection. Manual `mesl-cli up` instances are not supported while the guard is
armed. The controller never exempts an entire user account.

The guard owns a separate `inet mesl_guard` nftables table and survives ordinary
firewall reloads. If using `networking.nftables`, keep
`networking.nftables.flushRuleset = false`; configurations that flush the entire
ruleset are rejected. Administrative commands that flush all nftables tables
can remove protection. Disabling the option or MESL in a subsequent NixOS rebuild
removes the guard table during activation. No changes to the standalone package
or its CLI defaults are made.
