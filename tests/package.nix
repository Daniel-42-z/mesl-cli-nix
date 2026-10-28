{ pkgs, package }:
pkgs.runCommand "mesl-cli-package-check" { } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME" core
  ${package}/bin/mesl-cli version > version.txt
  grep -Fx 'mesl-cli ${package.version} (MeslClientForLinux/v${package.version})' version.txt
  ${package}/bin/mesl-cli --help | grep -F -- '--core PATH'
  test -x ${package}/libexec/mesl/mihomo
  test -s ${package}/libexec/mesl/geoip.metadb
  ${package}/libexec/mesl/mihomo -v
  cp ${package}/libexec/mesl/geoip.metadb core/
  cat > core/config.yaml <<'YAML'
  mixed-port: 0
  allow-lan: false
  mode: rule
  log-level: silent
  rules:
    - MATCH,DIRECT
  YAML
  ${package}/libexec/mesl/mihomo -t -d "$PWD/core" -f "$PWD/core/config.yaml"
  touch "$out"
''
