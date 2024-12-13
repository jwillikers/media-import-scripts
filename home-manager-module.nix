self:
{
  config,
  lib,
  pkgs,
  ...
}:
{
  home = {
    activation = {
      copy-calibre-plugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${pkgs.calibre}/bin/calibre-customize --add-plugin=${
          self.packages.${pkgs.stdenv.system}.calibrePlugins.acsm
          + "/lib/calibre/calibre-plugins/calibre-plugin.zip"
        }
        ${pkgs.calibre}/bin/calibre-customize --add-plugin=${
          self.packages.${pkgs.stdenv.system}.calibrePlugins.dedrm
          + "/lib/calibre/calibre-plugins/DeDRM_plugin.zip"
        }
        ${pkgs.calibre}/bin/calibre-customize --add-plugin=${
          self.packages.${pkgs.stdenv.system}.calibrePlugins.dedrm
          + "/lib/calibre/calibre-plugins/Obok_plugin.zip"
        }
        ${pkgs.calibre}/bin/calibre-customize --add-plugin=${
          self.packages.${pkgs.stdenv.system}.calibrePlugins.comicvine
          + "/lib/calibre/calibre-plugins/Comicvine.zip"
        }
        ${pkgs.calibre}/bin/calibre-customize --add-plugin=${
          self.packages.${pkgs.stdenv.system}.calibrePlugins.embedcomicmetadata
          + "/lib/calibre/calibre-plugins/EmbedComicMetadata.zip"
        }
        chmod +w ${config.xdg.configHome}/calibre/plugins/*.zip
      '';
    };
    file = {
      # "${config.xdg.configHome}/calibre/plugins/Comicvine.zip".source = self.packages.${pkgs.stdenv.system}.calibrePlugins.comicvine + "/lib/calibre/calibre-plugins/Comicvine.zip";
      # "${config.xdg.configHome}/calibre/plugins/DeACSM.zip".source = self.packages.${pkgs.stdenv.system}.calibrePlugins.acsm + "/lib/calibre/calibre-plugins/DeACSM.zip";
      # "${config.xdg.configHome}/calibre/plugins/DeDRM.zip".source = self.packages.${pkgs.stdenv.system}.calibrePlugins.dedrm + "/lib/calibre/calibre-plugins/DeDRM.zip";
      # "${config.xdg.configHome}/calibre/plugins/EmbedComicMetadata.zip".source = self.packages.${pkgs.stdenv.system}.calibrePlugins.embedcomicmetadata + "/lib/calibre/calibre-plugins/EmbedComicMetadata.zip";

      # todo Comic Vine API key for Calibre plugin from SOPS
      # "${config.xdg.configHome}/calibre/plugins/comicvine.json".contents = ''
      # {
      #   "api_key": "<API KEY>",
      #   "max_volumes": 2,
      #   "requests_rate": 1,
      #   "worker_threads": 16
      # }
      # '';

      # todo Comic Vine API key for ComicTagger from SOPS
    };
    packages =
      with pkgs;
      [
        calibre
        # comictagger
        keyfinder-cli # todo Fix beets to properly be wrapped with this?
        minio-client
      ]
      ++ (with self.packages.${pkgs.stdenv.system}; [
        media-juggler
      ]);
  };

  programs = {
    beets = {
      enable = true;
      package = pkgs.unstable.beets;
      # todo Add API keys when SOPS support is added.
      settings = {
        plugins = [
          "chroma"
          "embedart"
          "export"
          "fetchart"
          "keyfinder"
          "lyrics"
          "scrub"
        ];
        acoustid = {
          # apikey = "";
        };
        embedart = {
          remove_art_file = true;
        };
        fetchart = {
          # fanarttv_key = "";
          # google_key = "";
          high_resolution = true;
          # lastfm_key = "";
        };
        keyfinder = {
          bin = "keyfinder-cli";
        };
        lyrics = {
          # bing_client_secret = "";
          # bing_lang_to = "english";
          # google_API_key = "";
          synced = true;
        };
      };
    };
  };

  systemd.user = {
    tmpfiles.rules = [
      "d ${config.home.homeDirectory}/Books 0750 ${config.home.username} ${config.home.username} - -"
      "d ${config.home.homeDirectory}/Books/Audiobooks 0750 ${config.home.username} ${config.home.username} - -"
    ];
  };

  nixpkgs.overlays = [
    self.overlays.calibre-acsm-plugin-libcrypto
    self.overlays.unstablePackages
  ];
}
