{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
}:
let
  release = builtins.fromJSON (builtins.readFile ./release.json);
  sources = release.sources;
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "mesl-cli supports only x86_64-linux and aarch64-linux");
in
stdenvNoCC.mkDerivation {
  pname = "mesl-cli";
  inherit (release) version;

  src = fetchurl {
    inherit (source) url hash;
  };

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 mesl-cli "$out/libexec/mesl/mesl-cli"
    install -Dm755 mihomo "$out/libexec/mesl/mihomo"
    install -Dm644 geoip.metadb "$out/libexec/mesl/geoip.metadb"
    install -Dm644 README.md "$out/share/doc/mesl-cli/README.md"
    install -Dm644 mesl-cli.service "$out/share/doc/mesl-cli/mesl-cli.service"
    makeWrapper "$out/libexec/mesl/mesl-cli" "$out/bin/mesl-cli" \
      --set-default MESL_CORE "$out/libexec/mesl/mihomo"
    runHook postInstall
  '';

  meta = {
    description = "MESL command-line proxy client with its bundled Mihomo core";
    homepage = "https://client.meslapp.com";
    # The binary distribution provides no license grant for the MESL client.
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "mesl-cli";
  };
}
