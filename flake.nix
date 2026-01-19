{
  description = "Public beads devenv module for commit correlation across overengineering projects";

  outputs = { ... }: {
    # Devenv module for commit correlation
    # Usage: imports = [ (inputs.overeng-beads-public.devenvModules.beads { beadsPrefix = "eu"; beadsRepoName = "overeng-beads-public"; }) ];
    devenvModules.beads = import ./nix/devenv-module.nix;
  };
}
