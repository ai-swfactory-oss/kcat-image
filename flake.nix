{
  description = "Minimal OCI image with kcat (Kafka producer/consumer CLI), built with Nix";

  # The channel tarball only advances once Hydra has built it, so the build
  # tooling comes from cache.nixos.org. `nix flake update` pins it to an
  # immutable releases.nixos.org URL in flake.lock (no GitHub API involved).
  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

  outputs = { self, nixpkgs }:
    let
      # The image is Linux-only; the dev shell also covers Apple Silicon macOS
      # (nixpkgs unstable no longer supports x86_64-darwin).
      systems = [ "x86_64-linux" "aarch64-linux" ];
      devSystems = systems ++ [ "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Toolchain for working on this repo. claude-factory re-enters this shell
      # (`nix develop --command node ...`) whenever it runs inside the flake, so it
      # must provide node.
      devShells = nixpkgs.lib.genAttrs devSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in {
          default = pkgs.mkShell {
            packages = [ pkgs.nodejs_24 pkgs.git pkgs.gh pkgs.jq pkgs.actionlint ];
          };
        });

      packages = forAll (pkgs:
        let
          static = pkgs.pkgsStatic;

          # librdkafka without curl (OIDC token fetch) and SASL: plaintext and TLS only.
          rdkafka = static.rdkafka.overrideAttrs (old: {
            buildInputs = [ static.zlib static.zstd static.openssl ];
            cmakeFlags = old.cmakeFlags ++ [ "-DWITH_CURL=OFF" "-DWITH_SASL=OFF" ];
          });

          # Static kcat without Avro/Schema Registry support (avro-c, libserdes):
          # not needed for plain messages, and the heaviest, most fragile deps.
          kcatStatic = (static.kcat.override { avro-c = null; libserdes = null; inherit rdkafka; }).overrideAttrs (old: {
            buildInputs = [ static.zlib rdkafka static.yajl static.zstd static.openssl ];
            # librdkafka's pkg-config file declares no private deps; a static link needs them.
            preConfigure = (old.preConfigure or "") + ''
              export LIBS="-lssl -lcrypto -lzstd -lz -lpthread -lm"
            '';
          });

          licenseSources = [
            { name = "kcat"; src = kcatStatic.src; files = [ "LICENSE" "LICENSE.getdelim" "LICENSE.wingetopt" ]; }
            { name = "librdkafka"; src = rdkafka.src; files = [ "LICENSES.txt" ]; }
            { name = "openssl"; src = static.openssl.src; files = [ "LICENSE.txt" ]; }
            { name = "zstd"; src = static.zstd.src; files = [ "LICENSE" ]; }
            { name = "zlib"; src = static.zlib.src; files = [ "LICENSE" ]; }
            { name = "yajl"; src = static.yajl.src; files = [ "COPYING" ]; }
            { name = "musl"; src = static.stdenv.cc.libc.src; files = [ "COPYRIGHT" ]; }
          ];
        in
        rec {
          kcat = kcatStatic;

          # Image root filesystem: the stripped binary with every /nix/store reference
          # removed, plus the CA bundle. Nothing else, no store paths.
          rootfs = pkgs.runCommandCC "kcat-rootfs-${kcatStatic.version}"
            { nativeBuildInputs = [ pkgs.nukeReferences ]; }
            ''
              install -Dm755 ${kcatStatic}/bin/kcat $out/bin/kcat
              strip $out/bin/kcat
              nuke-refs $out/bin/kcat
              install -Dm444 ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-bundle.crt

              copy_licenses() {
                name=$1 src=$2
                shift 2
                if [ -d "$src" ]; then
                  dir=$src
                else
                  rm -rf unpacked && mkdir unpacked && tar -xf "$src" -C unpacked
                  dir=$(echo unpacked/*)
                fi
                for f in "$@"; do
                  install -Dm444 "$dir/$f" "$out/usr/share/licenses/$name/$f"
                done
              }
              ${pkgs.lib.concatMapStrings (l: "copy_licenses ${l.name} ${l.src} ${toString l.files}\n") licenseSources}
              install -Dm444 ${pkgs.spdx-license-list-data.text}/text/MPL-2.0.txt $out/usr/share/licenses/ca-certificates/MPL-2.0.txt
              cat > $out/usr/share/licenses/ca-certificates/NOTICE <<EOF
              /etc/ssl/certs/ca-bundle.crt is generated from Mozilla NSS certdata.txt (nss-cacert ${pkgs.cacert.version}), licensed under MPL-2.0.
              Source: ${builtins.head (pkgs.cacert.src.urls or [ pkgs.cacert.src.url ])}
              EOF
            '';

          image = pkgs.dockerTools.buildImage {
            name = "kcat";
            tag = "latest";
            copyToRoot = [ rootfs ];
            config = {
              Entrypoint = [ "/bin/kcat" ];
              User = "65534:65534";
              Env = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" ];
              Labels = {
                "org.opencontainers.image.source" = "https://github.com/ai-swfactory-oss/kcat-image";
                "org.opencontainers.image.description" = "Minimal static kcat (Kafka CLI) image built with Nix";
                "org.opencontainers.image.licenses" = "BSD-2-Clause AND BSD-3-Clause AND MIT AND ISC AND Zlib AND Apache-2.0 AND MPL-2.0";
                "org.opencontainers.image.version" = kcat.version;
              };
            };
          };

          default = image;
        });

      # Identifies the published image by content: a hash of both architectures'
      # image store paths. The registry tag nix-<imageKey> means "this exact image
      # is published"; the daily update builds whenever that tag is missing.
      imageKey = builtins.substring 0 16 (builtins.hashString "sha256"
        (builtins.concatStringsSep "," (map (s: self.packages.${s}.image.outPath) systems)));
    };
}
