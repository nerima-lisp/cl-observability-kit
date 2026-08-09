{
  description = "Transport-neutral observability substrate for Common Lisp";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    cl-nix-forge = {
      url = "github:nerima-lisp/cl-nix-forge/v0.5.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    cl-concurrent-kit = {
      url = "github:nerima-lisp/cl-concurrent-kit/v0.6.1";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
      inputs.cl-date-kit.follows = "cl-date-kit";
    };

    cl-date-kit = {
      url = "github:nerima-lisp/cl-date-kit/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    cl-boundary-kit = {
      url = "github:nerima-lisp/cl-boundary-kit/v2.3.0";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
    };

    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.3.0";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
    };

    cl-log-kit = {
      url = "github:nerima-lisp/cl-log-kit/v2.2.0";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
      inputs.cl-concurrent-kit.follows = "cl-concurrent-kit";
      inputs.cl-date-kit.follows = "cl-date-kit";
    };

    paredit-cli = {
      url = "github:nerima-lisp/paredit-cli/v1.6.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      cl-nix-forge,
      cl-concurrent-kit,
      cl-date-kit,
      cl-boundary-kit,
      cl-weave,
      cl-log-kit,
      paredit-cli,
      treefmt-nix,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
    in
    cl-nix-forge.lib.${builtins.head systems}.mkPackageFlake {
      inherit self systems nixpkgs;

      pname = "cl-observability-kit";
      asd = ./cl-observability-kit.asd;
      root = ./.;

      lispDependencies = ctx: [
        cl-concurrent-kit.packages.${ctx.system}.cl-concurrent-kit
        cl-boundary-kit.packages.${ctx.system}.cl-boundary-kit
      ];

      lispCheckDependencies = ctx: [
        cl-weave.packages.${ctx.system}.cl-weave
        cl-log-kit.packages.${ctx.system}.cl-log-kit
      ];

      timeoutSeconds = 120;

      docs = {
        root = ./.;
        mkdocsYmlName = "docs/mkdocs.yml";
      };

      treefmt.evalModule = treefmt-nix.lib.evalModule;

      devShellPackages = ctx: [
        paredit-cli.packages.${ctx.system}.default
      ];
    };
}
