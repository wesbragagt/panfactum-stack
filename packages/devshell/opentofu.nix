{ pkgs }:
let
  version = "1.13.0";
  platform =
    {
      "x86_64-linux" = {
        name = "linux_amd64";
        hash = "ad494034a03aaa66d93fc1c2c164d01bedf21b44cfb8b616182cb69424a67672";
      };
      "aarch64-linux" = {
        name = "linux_arm64";
        hash = "34dfd5c6d7de0372789d92dc0db52a9c710edac7cc2abef404a76a1fae6f2ef8";
      };
      "x86_64-darwin" = {
        name = "darwin_amd64";
        hash = "c4eea55d524073fc90244a035fb2c31a3f108bcedf16e7f449f0831e772d3287";
      };
      "aarch64-darwin" = {
        name = "darwin_arm64";
        hash = "6e03dc4d12df57c0f7da38cb963f28e8d0418eb6f0762a2fc5eb3988da6b396d";
      };
    }
    .${pkgs.stdenv.hostPlatform.system};
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "opentofu";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://github.com/opentofu/opentofu/releases/download/v${version}/tofu_${version}_${platform.name}.zip";
    sha256 = platform.hash;
  };
  nativeBuildInputs = [ pkgs.unzip ];
  dontUnpack = true;
  installPhase = ''
    mkdir -p "$out/bin"
    unzip -j "$src" tofu -d "$out/bin"
  '';
}
