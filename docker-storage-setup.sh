#!/bin/bash

#--
# Copyright 2014 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#++

#  Purpose:  This script grows the root filesystem and sets up LVM volumes
#            for docker metadata and data.
#  Author:   Andy Grimm <agrimm@redhat.com>

set -e

# This section reads the config file (/etc/sysconfig/docker-storage-setup. 
# Currently supported options:
# DEVS: A quoted, space-separated list of devices to be used.  This currently
#       expects the devices to be unpartitioned drives.  If "VG" is not
#       specified, then use of the root disk's extra space is implied.
#
# VG:   The volume group to use for docker storage.  Defaults to the volume
#       group where the root filesystem resides.  If VG is specified and the
#       volume group does not exist, it will be created (which requires that
#       "DEVS" be nonempty, since we don't currently support putting a second
#       partition on the root disk).
#
# The options below should be specified as values acceptable to 'lvextend -L':
#
# ROOT_SIZE: The size to which the root filesystem should be grown.
#
# DATA_SIZE: The desired size for the docker data LV.  Defaults to using all
#            free space in the VG after the root LV and docker metadata LV
#            have been allocated/grown.
#
# Other possibilities: 
# * Support lvm raid setups for docker data?  This would not be very difficult
# if given multiple PVs and another variable; options could be just a simple
# "mirror" or "stripe", or something more detailed.

# In lvm thin pool , effectively data LV is named as pool LV. lvconvert
# takes the data lv name and uses it as pool lv name. And later even to
# resize the data lv, one has to use pool lv name. So name data lv
# appropriately.
# Note: lvm2 version should be same or higher than lvm2-2.02.112 for lvm
# thin pool functionality to work properly.
POOL_LV_NAME="docker-pool"
DATA_LV_NAME=$POOL_LV_NAME
META_LV_NAME="${POOL_LV_NAME}meta"

OVERLAY_LV_NAME="docker-overlay-volume"

DOCKER_STORAGE="/etc/sysconfig/docker-storage"
STORAGE_DRIVERS="devicemapper overlay"

get_docker_version() {
	local version

	if ! version=$(docker version 2>/dev/null | grep "Client version" | cut -d ":" -f2 | sed 's/^ *//');then
		return 1
	fi
	echo $version
}

get_deferred_removal_string() {
	local version major minor

	if ! version=$(get_docker_version);then
		return 0
	fi
	[ -z "$version" ] && return 0

	major=$(echo $version | cut -d "." -f1)
	minor=$(echo $version | cut -d "." -f2)
	[ -z "$major" ] && return 0
	[ -z "$minor" ] && return 0

	# docker 1.7 onwards supports deferred device removal. Enable it.
	if [ "$major" -ge "1" ] && [ "$minor" -ge "7" ];then
		echo "--storage-opt dm.use_deferred_removal=true"
	fi
}

get_devicemapper_config_options() {
  local storage_options

  # docker expects device mapper device and not lvm device. Do the conversion.
  eval $( lvs --nameprefixes --noheadings -o lv_name,kernel_major,kernel_minor $VG | while read line; do
    eval $line
    if [ "$LVM2_LV_NAME" = "$DATA_LV_NAME" ]; then
      echo POOL_DEVICE_PATH=/dev/mapper/$( cat /sys/dev/block/${LVM2_LV_KERNEL_MAJOR}:${LVM2_LV_KERNEL_MINOR}/dm/name )
    fi
    done )

  storage_options="DOCKER_STORAGE_OPTIONS=--storage-driver devicemapper --storage-opt dm.fs=xfs --storage-opt dm.thinpooldev=$POOL_DEVICE_PATH $(get_deferred_removal_string)"
  echo $storage_options
}

get_overlay_config_options() {
  echo "DOCKER_STORAGE_OPTIONS=--storage-driver overlay"
}

write_storage_config_file () {
  local storage_options

  if [ "$STORAGE_DRIVER" == "devicemapper" ]; then
    if ! storage_options=$(get_devicemapper_config_options); then
      return 1
    fi
  elif [ "$STORAGE_DRIVER" == "overlay" ];then
    if ! storage_options=$(get_overlay_config_options); then
      return 1
    fi
  fi

cat <<EOF > $DOCKER_STORAGE.tmp
$storage_options
EOF
  mv $DOCKER_STORAGE.tmp $DOCKER_STORAGE
}

create_metadata_lv() {
  # If metadata lvm already exists (failures from previous run), then
  # don't create it.
  # TODO: Modify script to cleanup meta and data lvs if failure happened
  # later. Don't exit with error leaving partially created lvs behind.

  if lvs -a $VG/${META_LV_NAME} --noheadings &>/dev/null; then
        echo "Metadata volume $META_LV_NAME already exists. Not creating a new one."
	return 0
  fi

  # Reserve 0.1% of the free space in the VG for docker metadata.
  # Calculating the based on actual data size might be better, but is
  # more difficult do to the range of possible inputs.
  VG_SIZE=$( vgs --noheadings --nosuffix --units s -o vg_size $VG )
  META_SIZE=$(( $VG_SIZE / 1000 + 1 ))
  if [ ! -n "$META_LV_SIZE" ]; then
    lvcreate -y -L ${META_SIZE}s -n $META_LV_NAME $VG
  fi
}

create_data_lv() {
  if [ ! -n "$DATA_SIZE" ]; then
    echo "Data volume creation failed. No DATA_SIZE specified"
    exit 1
  fi

  # TODO: Error handling when DATA_SIZE > available space.
  if [[ $DATA_SIZE == *%* ]]; then
    lvcreate -y -l $DATA_SIZE -n $DATA_LV_NAME $VG
  else
    lvcreate -y -L $DATA_SIZE -n $DATA_LV_NAME $VG
  fi
}

create_lvm_thin_pool () {
  if [ -z "$DEVS" ] && [ -z "$VG_EXISTS" ]; then
    echo "Specified volume group $VG does not exists, and no devices were specified" >&2
    exit 1
  fi

  # First create metadata lv. Down the line let lvm2 create it automatically.
  create_metadata_lv
  create_data_lv

  if [ -n "$CHUNK_SIZE" ]; then
    CHUNK_SIZE_ARG="-c $CHUNK_SIZE"
  fi
  lvconvert -y --zero n $CHUNK_SIZE_ARG --thinpool $VG/$DATA_LV_NAME --poolmetadata $VG/$META_LV_NAME
}

setup_lvm_thin_pool () {
  if ! lvm_pool_exists; then
    create_lvm_thin_pool
    write_storage_config_file
  fi

  # Enable or disable automatic pool extension
  if [ "$AUTO_EXTEND_POOL" == "yes" ];then
    enable_auto_pool_extension ${VG} ${POOL_LV_NAME}
  else
    disable_auto_pool_extension ${VG} ${POOL_LV_NAME}
  fi
}

overlay_volume_exists() {
  lvs $VG/$OVERLAY_LV_NAME > /dev/null && return 0
  return 1
}

# Check if overlay volume is already bind mounted. This return 0 if overlay
# volume is already mounted on /var/lib/docker. Returns 1 if volumes needs
# mounting. On all other error conditions it exits.

is_overlay_mounted() {
  local mounts target

  if ! mounts=$(findmnt -n --first-only --source /dev/$VG/$OVERLAY_LV_NAME); then
    echo "Failed to get a list of existing overlay mount points."
    exit 1
  fi

  [ -z $mounts ] && return 1

  # If overlay volume is mounted, it should be mounted on /var/lib/docker
  # otherwise it is an error.
  target=`echo $mounts | cut -d " " -f1`
  [ "$target" == "$DOCKER_GRAPH_DIRECTORY" ] && return 0

  echo "Overlay volume /dev/$VG/$OVERLAY_LV_NAME is mounted on $target"
  exit 1
}

# Bind mount overlay volume on /var/lib/docker so that next docker start
# uses overlay on volume setup by the script.
mount_overlay_volume() {
  if ! mount -t xfs /dev/$VG/$OVERLAY_LV_NAME $DOCKER_GRAPH_DIRECTORY > /dev/null;then
    echo "Failed to mount overlay volume /dev/$VG/$OVERLAY_LV_NAME on ${DOCKER_GRAPH_DIRECTORY}"
    return 1
  fi

  return 0
}

setup_overlay_volume() {
  # Overlay volume does not exist. Create it and make fs.
  DATA_LV_NAME=$OVERLAY_LV_NAME

  if ! create_data_lv; then
    return 1
  fi

  if ! mkfs -t xfs /dev/$VG/$OVERLAY_LV_NAME; then
    echo "Failed to create filesystem on /dev/$VG/${OVERLAY_LV_NAME}."
    return 1
  fi

  if ! mount_overlay_volume; then
    return 1
  fi
}

setup_overlay_volume_fs() {
  [ "$OVERLAY_ON_NEW_VOLUME" != "yes" ] && return 0

  # Make sure DOCKER_GRAPH_DIRECTORY is specified
  if [ -z "$DOCKER_GRAPH_DIRECTORY" ]; then
    echo "Specify a valid DOCKER_GRAPH_DIRECTORY"
    return 1
  fi

  if [ ! -d "$DOCKER_GRAPH_DIRECTORY" ];then
    echo "DOCKER_GRAPH_DIRECTORY=${DOCKER_GRAPH_DIRECTORY} is not a valid directory"
    return 1
  fi

  is_overlay_mounted && return 0

  if overlay_volume_exists; then
     # Mount overlay and return.
     if ! mount_overlay_volume; then
       return 1
     else
       return 0
     fi
  fi

  # Overlay volume does not exist. Create one.
  if ! setup_overlay_volume; then
    echo "Failed to setup logical volume for overlay"
    return 1
  fi
}

setup_overlay () {
  if ! setup_overlay_volume_fs; then
    exit 1
  fi

  write_storage_config_file
}

lvm_pool_exists() {
  local lv_data
  local lvname lv lvsize

  lv_data=$( lvs --noheadings -o lv_name,lv_attr --separator , $VG | sed -e 's/^ *//')
  SAVEDIFS=$IFS
  for lv in $lv_data; do
  IFS=,
  read lvname lvattr <<< "$lv"
    # pool logical volume has "t" as first character in its attributes
    if [ "$lvname" == "$POOL_LV_NAME" ] && [[ $lvattr == t* ]]; then
            IFS=$SAVEDIFS
	    return 0
    fi
  done
  IFS=$SAVEDIFS

  return 1
}

# If a /etc/sysconfig/docker-storage file is present and if it contains
# dm.datadev or dm.metadatadev entries, that means we have used old mode
# in the past.
is_old_data_meta_mode() {
  if [ ! -f "$DOCKER_STORAGE" ];then
    return 1
  fi

  if ! grep -e "^DOCKER_STORAGE_OPTIONS=.*dm\.datadev" -e "^DOCKER_STORAGE_OPTIONS=.*dm\.metadatadev" $DOCKER_STORAGE  > /dev/null 2>&1;then
    return 1
  fi

  return 0
}

grow_root_pvs() {
  [ -x "/usr/bin/growpart" ] || return 0

  # Grow root pvs only if user asked for it through config file.
  [ "$GROWPART" != "true" ] && return

  # Note that growpart is only variable here because we may someday support
  # using separate partitions on the same disk.  Today we fail early in that
  # case.  Also note that the way we are doing this, it should support LVM
  # RAID for the root device.  In the mirrored or striped case, we are growing
  # partitions on all disks, so as long as they match, growing the LV should
  # also work.
  for pv in $ROOT_PVS; do
    # Split device & partition.  Ick.
    growpart $( echo $pv | sed -r 's/([^0-9]*)([0-9]+)/\1 \2/' ) || true
    pvresize $pv
  done
}

grow_root_lv_fs() {
  if [ -n "$ROOT_SIZE" ]; then
    # TODO: Error checking if specified size is <= current size
    lvextend -r -L $ROOT_SIZE $ROOT_DEV || true
  fi
}

create_disk_partitions() {
  for dev in $DEVS; do
    if expr match $dev ".*[0-9]" > /dev/null; then
      echo "Partition specification unsupported at this time." >&2
      exit 1
    fi
    if [[ $dev != /dev/* ]]; then
      dev=/dev/$dev
    fi
    # Use a single partition of a whole device
    # TODO:
    #   * Consider gpt, or unpartitioned volumes
    #   * Error handling when partition(s) already exist
    #   * Deal with loop/nbd device names. See growpart code
    PARTS=$( awk "\$4 ~ /"$( basename $dev )"[0-9]/ { print \$4 }" /proc/partitions )
    if [ -n "$PARTS" ]; then
      echo "$dev has partitions: $PARTS"
      exit 1
    fi
    size=$(( $( awk "\$4 ~ /"$( basename $dev )"/ { print \$3 }" /proc/partitions ) * 2 - 2048 ))
    cat <<EOF | sfdisk $dev
unit: sectors

${dev}1 : start=     2048, size=  ${size}, Id=8e
EOF
    pvcreate ${dev}1
    PVS="$PVS ${dev}1"
  done
}

create_extend_volume_group() {
  if [ -z "$VG_EXISTS" ]; then
    vgcreate $VG $PVS
  else
    # TODO:
    #   * Error handling when PV is already part of a VG
    vgextend $VG $PVS
  fi
}

# Auto extension logic. Create a profile for pool and attach that profile
# the pool volume.
enable_auto_pool_extension() {
  local volume_group=$1
  local pool_volume=$2
  local profileName="${volume_group}--${pool_volume}-extend"
  local profileFile="${profileName}.profile"
  local profileDir
  local tmpFile=`mktemp -t tmp.XXXXX`

  profileDir=$(lvm dumpconfig | grep "profile_dir" | cut -d "=" -f2 | sed 's/"//g')
  [ -n "$profileDir" ] || return 1

  if [ ! -n "$POOL_AUTOEXTEND_THRESHOLD" ];then
    echo "POOL_AUTOEXTEND_THRESHOLD not specified"
    return 1
  fi

  if [ ! -n "$POOL_AUTOEXTEND_PERCENT" ];then
    echo "POOL_AUTOEXTEND_PERCENT not specified"
    return 1
  fi

cat <<EOF > $tmpFile
activation {
	thin_pool_autoextend_threshold=${POOL_AUTOEXTEND_THRESHOLD}
	thin_pool_autoextend_percent=${POOL_AUTOEXTEND_PERCENT}

}
EOF
  mv $tmpFile ${profileDir}/${profileFile}
  lvchange --metadataprofile ${profileName}  ${volume_group}/${pool_volume}
}

disable_auto_pool_extension() {
  local volume_group=$1
  local pool_volume=$2
  local profileName="${volume_group}--${pool_volume}-extend"
  local profileFile="${profileName}.profile"
  local profileDir

  profileDir=$(lvm dumpconfig | grep "profile_dir" | cut -d "=" -f2 | sed 's/"//g')
  [ -n "$profileDir" ] || return 1

  lvchange --detachprofile ${volume_group}/${pool_volume}
  rm -f ${profileDir}/${profileFile}
}


# Gets the current DOCKER_STORAGE_OPTIONS= string.
get_docker_storage_options() {
  local options
  if options=$(grep -e "^DOCKER_STORAGE_OPTIONS=" $DOCKER_STORAGE | sed 's/DOCKER_STORAGE_OPTIONS=//' | sed 's/^ *//');then
    echo $options
    return 0
  fi

  return 1
}

is_valid_storage_driver() {
  local driver=$1 d

  for d in $STORAGE_DRIVERS;do
    [ "$driver" == "$d" ] && return 0
  done

  return 1
}

# Gets the existing storage driver configured in /etc/sysconfig/docker-storage
get_existing_storage_driver() {
  local options driver

  if [ ! -f "$DOCKER_STORAGE" ];then
    return 0
  fi

  if ! options=$(get_docker_storage_options); then
    return 1
  fi

  # DOCKER_STORAGE_OPTIONS= is empty there is no storage driver configured yet.
  [ -z "$options" ] && return 0

  # Check if -storage-driver <driver> is there.
  if ! driver=$(echo $options | sed -n 's/.*\(--storage-driver [ ]*[a-z]*\).*/\1/p' | sed 's/--storage-driver *//');then
    return 1
  fi

  if [ -n "$driver" ] && [ ! "$driver" == "$options" ];then
    echo $driver
    return 0
  fi

  # Check if -s <driver> is there.
  if ! driver=$(echo $options | sed -n 's/.*\(-s [ ]*[a-z]*\).*/\1/p' | sed 's/-s *//');then
    return 1
  fi

  # If pattern does not match then driver == options.
  if [ -n "$driver" ] && [ ! "$driver" == "$options" ];then
    echo $driver
    return 0
  fi

  # We shipped some versions where we did not specify -s devicemapper.
  # If dm.thinpooldev= is present driver is devicemapper.
  if echo $options | grep -q -e "--storage-opt dm.thinpooldev=";then
    echo "devicemapper"
    return 0
  fi

  #Failed to determine existing storage driver.
  return 1
}

setup_storage() {
  local current_driver

  if [ "$STORAGE_DRIVER" == "" ];then
    echo "No storage driver specified. Specify one using STORAGE_DRIVER option."
    exit 0
  fi

  if ! is_valid_storage_driver $STORAGE_DRIVER;then
    echo "Invalid storage driver: ${STORAGE_DRIVER}."
    exit 1
  fi

  if ! current_driver=$(get_existing_storage_driver);then
    echo "Failed to determine existing storage driver."
    exit 1
  fi

  # If storage is configured and new driver should match old one.
  if [ -n "$current_driver" ] && [ "$current_driver" != "$STORAGE_DRIVER" ];then
   echo "Storage is already configured with ${current_driver} driver. Can't configure it with ${STORAGE_DRIVER} driver. To override, remove $DOCKER_STORAGE and retry."
   exit 1
  fi

  # Set up lvm thin pool LV
  if [ "$STORAGE_DRIVER" == "devicemapper" ]; then
    setup_lvm_thin_pool
  elif [ "$STORAGE_DRIVER" == "overlay" ];then
    setup_overlay
  fi
}

usage() {
  echo "Usage: $1 [OPTIONS]"
  echo
  echo "Grows the root filesystem and sets up storage for docker."
  echo
  echo "Options:"
  echo "  -h, --help		Print help message."
}

# Main Script

if [ $# -gt 0 ]; then
  usage $0
  exit 0
fi

if [ -e /usr/lib/docker-storage-setup/docker-storage-setup ]; then
  source /usr/lib/docker-storage-setup/docker-storage-setup
fi

# If user has overridden any settings in /etc/sysconfig/docker-storage-setup
# take that into account.
if [ -e /etc/sysconfig/docker-storage-setup ]; then
  source /etc/sysconfig/docker-storage-setup
fi

# Read mounts
ROOT_DEV=$( awk '$2 ~ /^\/$/ && $1 !~ /rootfs/ { print $1 }' /proc/mounts )
ROOT_VG=$( lvs --noheadings -o vg_name $ROOT_DEV | sed -e 's/^ *//' -e 's/ *$//')
ROOT_PVS=$( pvs --noheadings -o pv_name,vg_name | awk "\$2 ~ /^$ROOT_VG\$/ { print \$1 }" )

VG_EXISTS=
if [ -z "$VG" ]; then
  VG=$ROOT_VG
  VG_EXISTS=1
else
  for vg_name in $( vgs --noheadings -o vg_name ); do
    if [ "$vg_name" == "$VG" ]; then
      VG_EXISTS=1
      break
    fi
  done
fi

if [ -n "$DEVS" ] ; then
  create_disk_partitions
  create_extend_volume_group
fi

grow_root_pvs

# NB: We are growing root here first, because when root and docker share a
# disk, we'll default to giving some portion of remaining space to docker.
grow_root_lv_fs

if is_old_data_meta_mode; then
  echo "ERROR: Old mode of passing data and metadata logical volumes to docker is not supported. Exiting."
  exit 1
fi

setup_storage
