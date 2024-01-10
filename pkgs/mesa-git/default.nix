{ final
, final64 ? final
, flakes
, nyxUtils
, prev
, gitOverride
, gbmDriver ? false
, gbmBackend ? "dri_git"
, mesaTestAttrs ? final
, ...
}:

let
  inherit (final.stdenv) is32bit;

  cargoDeps = {
    proc-macro2 = { version = "1.0.70"; hash = "sha256-OSePu/X7T2Rs5lFpCHf4nRxYEaPUrLJ3AMHLPNt4/Ts="; };
    quote = { version = "1.0.33"; hash = "sha256-Umf8pElgKGKKlRYPxCOjPosuavilMCV54yLktSApPK4="; };
    syn = { version = "2.0.39"; hash = "sha256-I+eLkPL89F0+hCAyzjLj8tFUW6ZjYnHcvyT6MG2Hvno="; };
    unicode-ident = { version = "1.0.12"; hash = "sha256-M1S5rD+uH/Z1XLbbU2g622YWNPZ1V5Qt6k+s6+wP7ks="; };
  };

  revert_mr_26943 = final.fetchpatch {
    url = "https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/26943.diff";
    hash = "sha256-KwIG68mf+aArMlvWBtGJdOFdCn5zTZJG6geWXE7bK44=";
    revert = true;
  };

  revert_mr_24386_1 = final.fetchpatch {
    url = "https://github.com/chaotic-cx/mesa-mirror/commit/299f9497758ca5d7278e5aafd210aa91d20dfb4d.patch";
    hash = "sha256-ugrkIqJ/Tndimn6YIQSanLVvQ5qZfp2m6GGStHLt8xg=";
    revert = true;
  };

  revert_mr_24386_2 = final.fetchpatch {
    url = "https://github.com/chaotic-cx/mesa-mirror/commit/1e5bc00715ad8acf3dc323278d0d6a24986bb4ae.patch";
    hash = "sha256-i0+sBeU/c8Eo8WA34aJfMLJOxhd7146+t7H6llGwS+g=";
    revert = true;
  };
in
gitOverride (current: {
  newInputs =
    if is32bit then with final64; {
      meson = meson32_1_3;
      directx-headers = directx-headers32_1_611;
      libdrm = libdrm32_git;
    } else with final; {
      meson = meson_1_3;
      directx-headers = directx-headers_1_611;
      libdrm = libdrm_git;
      # We need to mention those besides "all", because of the usage of nix's `lib.elem` in
      # the original derivation.
      galliumDrivers = [ "all" "zink" "d3d12" ];
      vulkanDrivers = [ "all" "microsoft-experimental" ];
      # Instead, we enable the new option in `mesonFlags`
      enablePatentEncumberedCodecs = false;
    };

  nyxKey = if is32bit then "mesa32_git" else "mesa_git";
  prev = prev.mesa;

  versionNyxPath = "pkgs/mesa-git/version.json";
  fetcher = "fetchFromGitHub";
  fetcherData = {
    owner = "chaotic-cx";
    repo = "mesa-mirror";
  };
  withUpdateScript = !is32bit;
  version = builtins.substring 0 (builtins.stringLength prev.mesa.version) current.rev;

  postOverride = prevAttrs: {
    mesonFlags =
      builtins.map
        (builtins.replaceStrings [ "virtio-experimental" ] [ "virtio" ])
        prevAttrs.mesonFlags
      ++ final.lib.optional (!is32bit) "-D video-codecs=all";

    patches =
      (nyxUtils.removeByBaseName
        "disk_cache-include-dri-driver-path-in-cache-key.patch"
        (nyxUtils.removeByBaseName
          "opencl.patch"
          prevAttrs.patches
        )
      ) ++ [
        ./opencl.patch
        ./disk_cache-include-dri-driver-path-in-cache-key.patch
        ./gbm-backend.patch
      ] ++ final.lib.optionals (!is32bit) [
        revert_mr_26943
        revert_mr_24386_1
        revert_mr_24386_2
      ];

    # expose gbm backend and rename vendor (if necessary)
    outputs =
      if gbmDriver
      then prevAttrs.outputs ++ [ "gbm" ]
      else prevAttrs.outputs;

    postPatch =
      let
        cargoFetch = who: final.fetchurl {
          url = "https://crates.io/api/v1/crates/${who}/${cargoDeps.${who}.version}/download";
          inherit (cargoDeps.${who}) hash;
        };

        cargoSubproject = who: ''
          ln -s ${cargoFetch who} subprojects/packagecache/${who}-${cargoDeps.${who}.version}.tar.gz
        '';

        # allow renaming the new backend name
        backendRename =
          if gbmBackend != "dri_git" then ''
            sed -i"" 's/"dri_git"/"${gbmBackend}"/' src/gbm/backends/dri/gbm_dri.c src/gbm/main/backend.c
          '' else "";
      in
      prevAttrs.postPatch
      + backendRename
      + ''
        mkdir subprojects/packagecache
      ''
      + (cargoSubproject "proc-macro2")
      + (cargoSubproject "quote")
      + (cargoSubproject "syn")
      + (cargoSubproject "unicode-ident");

    # move new backend to its own output (if necessary)
    postInstall =
      if gbmDriver then prevAttrs.postInstall + ''
        mkdir -p $gbm/lib/gbm
        ln -s $out/lib/libgbm.so $gbm/lib/gbm/${gbmBackend}_gbm.so
      '' else prevAttrs.postInstall;

    # test and accessible information
    passthru = prevAttrs.passthru // {
      inherit gbmBackend;
      tests.smoke-test = import ./test.nix
        {
          inherit (flakes) nixpkgs;
          chaotic = flakes.self;
        }
        mesaTestAttrs;
    };
  };
})
