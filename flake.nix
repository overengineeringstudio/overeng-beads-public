{
  description = "Public beads devenv module for commit correlation across overengineering projects";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }: {
    # Devenv module for commit correlation
    # Usage: imports = [ (inputs.overeng-beads-public.devenvModules.beads { beadsPrefix = "oep"; beadsRepoName = "overeng-beads-public"; }) ];
    devenvModules.beads = import ./nix/devenv-module.nix;
  };
}
