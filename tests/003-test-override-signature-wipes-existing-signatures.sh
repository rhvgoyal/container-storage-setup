source $SRCDIR/libtest.sh

cleanup() {
  local vg_name=$1
  local devs=$2

  vgremove -y $vg_name >> $LOGS 2>&1
  remove_pvs "$devs"
  remove_partitions "$devs"
  clean_config_files
  wipe_signatures "$devs"
}

test_override_signatures() {
  local devs=$DEVS dev
  local test_status
  local testname=`basename "$0"`
  local vg_name
  local vg_name="dss-test-foo"

 # Error out if any pre-existing volume group vg named dss-test-foo
  for vg in $(vgs --noheadings -o vg_name); do
    if [ "$vg" == "$vg_name" ]; then
      echo "ERROR: $testname: Volume group $vg_name already exists."
      return 1
    fi
  done

  # Create config file
  clean_config_files
  cat << EOF > /etc/sysconfig/docker-storage-setup
DEVS="$devs"
VG=$vg_name
WIPE_SIGNATURES=true
EOF

  # create lvm signatures on disks
  for dev in $devs; do
    pvcreate -f $dev >> $LOGS 2>&1
  done

  test_status=1
  # Run docker-storage-setup
  $DSSBIN >> $LOGS 2>&1

  # Test failed.
  if [ $? -ne 0 ]; then
    cleanup $vg_name $devs
    return 1
  fi

  # Make sure volume group $VG got created.
  for vg in $(vgs --noheadings -o vg_name); do
    if [ "$vg" == "$vg_name" ]; then
      test_status=0
      break
    fi
  done

  cleanup $vg_name $devs
  return $test_status
}

# Create a disk with some signature, say lvm signature and make sure
# override signature can override that, wipe signature and create thin
# pool.
test_override_signatures
