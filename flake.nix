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

  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-master,
      utils,
      devenv-node,
      devenv-nix,
      ...
    }:
    utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        sandcastle = pkgs.buildNpmPackage {
          pname = "sandcastle";
          version = "0.0.37";

          src = pkgs.lib.cleanSource ./.;

          npmDepsHash = "sha256-LMqLtMWMmzEiHW+VJAPnivqHtoJV2wWWP2S8Z/smfWc=";

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
        };
      in
      {
        formatter = pkgs.nixfmt;

        packages = {
          sandcastle = sandcastle;
          default = sandcastle;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            (pkgs.bats.withLibraries (p: [ p.bats-support p.bats-assert ]))
            pkgs.just
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
