{
  description = "OpenComputers programs for GregTech New Horizons";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    devShells = forAllSystems (pkgs: {
      # OpenOS 1.8.9 runs Lua 5.3, so the checks run on the same version
      default = pkgs.mkShell {
        packages = [pkgs.lua5_3 pkgs.luaPackages.luacheck];
      };
    });

    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
