{
  makeSetupHook,
  writeScript,
}:

makeSetupHook
  {
    name = "sower-services-hook";
    meta = {
      description = "Install systemd services from `sowerServices` for use in a sower services package";
    };
  }
  (
    writeScript "sower-services-hook.sh" # bash
      ''
        _sowerServicesHook() {
          echo "Installing Sower Services"

          mkdir -p $out/.sower/systemd/system

          # copy over top-level system directories, which likely include links to units
          find $sowerServices -mindepth 1 -type d | while read dir; do
            cp --recursive $dir $out/.sower/systemd/system/
          done

          # copy the unit files
          find $sowerServices -maxdepth 1 -type l | while read unit; do
            cp --dereference $unit $out/.sower/systemd/system/ || true
          done

          # replace PLACEHOLDER_OUT with package $out
          find $out/.sower/systemd/ -type f | while read unit; do
            chmod +w $unit
            sed -i "s,PLACEHOLDER_OUT,$out," $unit
          done

          # delete any empty dirs
          find $out/.sower/systemd -type d -empty -delete
        }

        preInstallHooks+=(_sowerServicesHook)
      ''
  )
