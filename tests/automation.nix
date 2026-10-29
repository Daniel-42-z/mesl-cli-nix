{ pkgs, source }:
pkgs.runCommand "mesl-automation-check"
  {
    nativeBuildInputs = with pkgs; [
      python3
      jujutsu
      gitMinimal
      ruff
      actionlint
      shellcheck
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    cp -r ${source} source
    chmod -R u+w source
    cd source
    python3 -m unittest discover -s tests -p 'test_*.py' -v
    ruff check guard.py scripts tests
    ruff format --check guard.py scripts tests
    actionlint .github/workflows/*.yml
    shellcheck scripts/validate.sh
    touch "$out"
  ''
