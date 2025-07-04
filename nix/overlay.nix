final: prev:
with final.lib;
with final.haskell.lib;
{
  haskellPackages = prev.haskellPackages.override (old: {
    overrides = final.lib.composeExtensions (old.overrides or (_: _: { })) (self: _:
      {
        prometheus-wai = buildStrictly (self.callPackage ../prometheus-wai { });
      }
    );
  });
}
