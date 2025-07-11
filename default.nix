{
  pkgs ?
    import (fetchTarball {
      url = "https://github.com/NixOS/nixpkgs/archive/refs/tags/25.05.tar.gz";
      sha256 = "sha256-rWtXrcIzU5wm/C8F9LWvUfBGu5U5E7cFzPYT1pHIJaQ=";
    }) {},
}:
with pkgs;
  stdenv.mkDerivation {
    pname = "projavu";
    version = "0.2.0";
    src = ./.;
    nativeBuildInputs = [zig.hook];
  }
