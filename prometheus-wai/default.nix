{ mkDerivation, autoexporter, base, bytestring, containers
, http-types, lib, prometheus, text, wai
}:
mkDerivation {
  pname = "prometheus-wai";
  version = "0.0.0.0";
  src = ./.;
  libraryHaskellDepends = [
    base bytestring containers http-types prometheus text wai
  ];
  libraryToolDepends = [ autoexporter ];
  homepage = "https://github.com/NorfairKing/prometheus-wai#readme";
  license = lib.licenses.mit;
}
