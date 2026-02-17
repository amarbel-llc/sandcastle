{
  description = "sandcastle - Anthropic sandbox runtime wrapped for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/23d72dabcb3b12469f57b37170fcbc1789bd7457";
    nixpkgs-master.url = "github:NixOS/nixpkgs/b28c4999ed71543e71552ccfd0d7e68c581ba7e9";
    utils.url = "https://flakehub.com/f/numtide/flake-utils/0.1.102";

    devenv-node = {
      url = "github:amarbel-llc/eng?dir=devenvs/node";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    devenv-nix = {
      url = "github:amarbel-llc/eng?dir=devenvs/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    batman = {
      url = "github:amarbel-llc/batman";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-master,
      utils,
      devenv-node,
      devenv-nix,
      batman,
      ...
    }:
    utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        sandcastle = pkgs.buildNpmPackage {
          pname = "sandcastle";
          version = "0.0.37";

          src = pkgs.fetchFromGitHub {
            owner = "anthropic-experimental";
            repo = "sandbox-runtime";
            rev = "96800ee98b66ac4029c22b04cb19950dc85afb11";
            hash = "sha256-lxsuC9l3T/DiP5ZNMgCzeJHBxxXLhfi/G4cTmUI2WWU=";
          };

          npmDepsHash = "sha256-eShe2ag5ASR2nSDlk/aYaANuAQS7d+fkZ+ydyuSt06w=";

          nativeBuildInputs = [ pkgs.makeWrapper ];

          buildPhase = ''
            runHook preBuild
            npm run build
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/sandcastle $out/bin

            cp -r dist/* $out/lib/sandcastle/
            cp -r node_modules $out/lib/sandcastle/
            cp package.json $out/lib/sandcastle/
            cp ${./sandcastle-cli.mjs} $out/lib/sandcastle/sandcastle-cli.mjs

            makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/sandcastle \
              --add-flags "$out/lib/sandcastle/sandcastle-cli.mjs" \
              --prefix PATH : ${
                pkgs.lib.makeBinPath (
                  [
                    pkgs.socat
                    pkgs.ripgrep
                  ]
                  ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.bubblewrap ]
                )
              }

            runHook postInstall
          '';

          dontNpmBuild = true;
        };
      in
      {
        formatter = pkgs.nixfmt;

        packages = {
          sandcastle = sandcastle;
          default = sandcastle;
        };

        devShells.default = pkgs.mkShell {
          packages = (with pkgs; [
            bats
            just
          ]) ++ [
            batman.packages.${system}.bats-libs
            sandcastle
          ];

          inputsFrom = [
            devenv-node.devShells.${system}.default
            devenv-nix.devShells.${system}.default
          ];
        };
      }
    );
}
