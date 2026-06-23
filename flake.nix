{
  description = "Claude status (status.claude.com) Tidbyt app";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = { };
          overlays = [ ];
        };

        pixletVersion = "0.34.0";

        pixletPlatform = {
          "x86_64-linux" = {
            arch = "linux_amd64";
            hash = "sha256-WDPQcRgD3WN05pal0CRi92aymd9kE0hgIftANdzFRkA=";
          };
          "aarch64-linux" = {
            arch = "linux_arm64";
            hash = "sha256-uMOGF5weXt+gSG6U9/ZJ7g7tFY7UeeAVdI+viqUkbq4=";
          };
          "x86_64-darwin" = {
            arch = "darwin_amd64";
            hash = "sha256-dwLoTD8hyA6Y/FjPDT9ulpC/5o8VwBKJ6xF0PS2KcPQ=";
          };
          "aarch64-darwin" = {
            arch = "darwin_arm64";
            hash = "sha256-AjZhSBQj7kdOMl0xupwTww4SmI0pnP8DIGJzdoPkIyg=";
          };
        }.${system} or (throw "unsupported system: ${system}");

        pixlet = pkgs.stdenvNoCC.mkDerivation {
          pname = "pixlet";
          version = pixletVersion;

          src = pkgs.fetchurl {
            url = "https://github.com/tidbyt/pixlet/releases/download/v${pixletVersion}/pixlet_${pixletVersion}_${pixletPlatform.arch}.tar.gz";
            hash = pixletPlatform.hash;
          };

          sourceRoot = ".";
          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall
            install -Dm755 pixlet $out/bin/pixlet
            install -Dm644 LICENSE.txt $out/share/doc/pixlet/LICENSE.txt
            install -Dm644 README.md   $out/share/doc/pixlet/README.md
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Build apps for the Tidbyt 64x32 pixel display";
            homepage = "https://github.com/tidbyt/pixlet";
            license = licenses.asl20;
            mainProgram = "pixlet";
            platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
          };
        };

        # The app pulls only a public, unauthenticated endpoint, so the
        # config.yaml carries Tidbyt push creds only (no upstream key).
        configContents = builtins.getEnv "CLAUDESTAT_CONFIG_YAML";

        configYaml = pkgs.writeText "claudestat-config.yaml" configContents;

        entrypoint = pkgs.writeShellScript "claudestat-loop" ''
          set -u

          if [ ! -s /app/config.yaml ]; then
            echo "FATAL: /app/config.yaml is empty — was CLAUDESTAT_CONFIG_YAML set at build time?" >&2
            exit 1
          fi

          TIDBYT_KEY=$(yq -r '.tidbyt_api_key' /app/config.yaml)
          DEVICE_ID=$(yq -r '.tidbyt_device_id' /app/config.yaml)
          INSTALL_ID=$(yq -r '.tidbyt_installation_id' /app/config.yaml)

          INTERVAL=''${PUSH_INTERVAL_S:-600}

          echo "claudestat daemon: push every ''${INTERVAL}s to device ''${DEVICE_ID} (installation ''${INSTALL_ID})"

          while true; do
            ts=$(date -uIs)
            if pixlet render /app/main.star -o /tmp/frame.webp 2>&1; then
              if pixlet push \
                  --api-token "''${TIDBYT_KEY}" \
                  --installation-id "''${INSTALL_ID}" \
                  "''${DEVICE_ID}" \
                  /tmp/frame.webp 2>&1; then
                echo "[''${ts}] push ok"
              else
                echo "[''${ts}] push FAILED"
              fi
            else
              echo "[''${ts}] render FAILED"
            fi
            sleep "''${INTERVAL}"
          done
        '';

        container = pkgs.dockerTools.buildLayeredImage {
          name = "claudestat";
          tag = "latest";

          contents = (with pkgs; [
            bashInteractive
            coreutils
            yq-go
            cacert
            tzdata
          ]) ++ [ pixlet ];

          extraCommands = ''
            mkdir -p app tmp
            cp ${./main.star} app/main.star
            cp ${configYaml} app/config.yaml
            cp ${entrypoint} app/loop.sh
            chmod 0755 app/loop.sh
            chmod 0600 app/config.yaml
          '';

          config = {
            WorkingDir = "/app";
            Cmd = [ "/bin/bash" "/app/loop.sh" ];
            Env = [
              "PATH=/bin"
              "TZ=UTC"
              "ZONEINFO=${pkgs.tzdata}/share/zoneinfo"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              "PUSH_INTERVAL_S=600"
            ];
            Labels = {
              "org.opencontainers.image.title" = "claudestat";
              "org.opencontainers.image.description" = "Claude status (status.claude.com) push daemon for Tidbyt";
              "org.opencontainers.image.source" = "https://status.claude.com/api/v2/summary.json";
            };
          };
        };
      in
      {
        packages = {
          pixlet = pixlet;
          container = container;
          default = pixlet;
        };

        devShells.default = pkgs.mkShell {
          name = "claudestat-tidbyt";
          packages = (with pkgs; [
            yq-go
            jq
            curl
            python3
            bash
            coreutils
          ]) ++ [ pixlet ];

          shellHook = ''
            echo ""
            echo "Claude Status Tidbyt dev shell"
            echo "  pixlet $(pixlet version 2>/dev/null || echo 'v${pixletVersion}')"
            echo ""
            if [ ! -f config.yaml ]; then
              echo "  ! config.yaml is missing — run:"
              echo "      cp config-example.yaml config.yaml   # then fill in your Tidbyt keys"
              echo ""
            fi
            echo "  Develop:"
            echo "    ./scripts/check.sh           Verify status.claude.com + summarize current state"
            echo "    ./scripts/preview.sh         Browser preview at http://localhost:8080"
            echo "    ./scripts/render.sh          Render one frame to out.webp"
            echo "    ./scripts/deploy.sh          One-shot push to your Tidbyt"
            echo ""
            echo "  Daemon (container):"
            echo "    ./scripts/build-container.sh Build OCI image, load into podman"
            echo "    ./scripts/run-container.sh   Run daemon (push every 10 min)"
            echo ""
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
