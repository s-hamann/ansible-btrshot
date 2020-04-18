#!/bin/bash
# btrshot v0.1.1


# loglevel constants
readonly ERROR=0
readonly WARN=1
readonly INFO=2
readonly DEBUG=3


function usage() {
    # Prints a usage message.
cat - <<EOH
$(basename -- "$0") [<options>] [--] <source subvol> <snapshots subvol> <tag> [<keep>]
  <source subvol> is the mount point of the subvolume to take a snapshot of.
  <snapshots subvol> is the mount point of the subvolume to store the snapshot.
    If either subvolume is not mounted, it will be mounted according to
    /etc/fstab for the snapshot (and unmounted afterwards).
  The snapshot will be put in a directory named <tag> on the snapshots
    subvolume. When purging old snapshots, only snapshots with the same tag are
    considered.
  <keep> determines how many existing snapshots with the same tag to keep.
    By default, all old snapshots are kept.
The following options are valid:
  --alias <name>|<path>
      Make an additional snapshot with the given <name> and the same contents
      in the <tag> directory or with the given <path> relative to the snapshot
      subvolume. If there already is a snapshot with that name, it is replaced.
  -d, --device <device>
      Device that contains the source and snapshot subvolumes. If this is
      given, <source subvol> and <snapshots subvol> are interpreted as
      subvolume names on that device instead of mount points.
      The device will be mounted to a temporary mount point.
  -r, --read-only
      Make a read-only snapshot.
  -f, --time-format <format>
      Format for the timestamp in the name of each snapshot.
      See date(1) for valid format specification.
  --colour, --no-colour
      Enable/disable coloured output. By default colours are enabled only if
      the output goes to a terminal.
  -v, --verbose
      Display additional status messages.
  -q, --quiet
      Display fewer status messages. Use twice to get error messages only.
Example:
  $(basename -- "$0") -r -q / /.snapshots manual
Note:
  Option arguments need to be before the positional arguments.
  Short options can not be combined into one parameter, i.e. -vr is invalid.
EOH
}


function echo_msg() {
    # usage: echo_msg <lvl> <message>
    # Prints the correctly coloured <message> if $lvl is below the desired threshold.
    local lvl=$1
    shift
    [[ "${lvl}" -gt "${loglevel}" ]] && return
    if ${colour}; then
        case ${lvl} in
            $DEBUG)
                printf '\e[34;1m' >&2 # blue
                ;;
            $INFO)
                printf '\e[32;1m' >&2 # green
                ;;
            $WARN)
                printf '\e[33;1m' >&2 # yellow
                ;;
            $ERROR)
                printf '\e[31;1m' >&2 # red
                ;;
        esac
    fi
    echo "$@" >&2
    if ${colour}; then
        printf '\e[0m' >&2
    fi
}


function die() {
    # usage: die <return code> <message>
    # Prints <message>, cleans up and exits with <return code>.
    local code="$1"
    shift
    echo_msg $ERROR "$@"
    cleanup
    exit "${code}"
}


function make_bootable() {
    # usage: make_bootable <snapshot_path> <original_subvol_name> <new_subvol_name>
    # Makes the snapshot bootable by making the /etc/fstab within the snapshot
    # reference the snapshot instead of the usual root subvolume.
    local snapshot_path="$1"
    local original_subvol_name="$2"
    local new_subvol_name="$3"
    [[ -z "${snapshot_path}" ]] && return
    echo_msg $DEBUG "Attempting to make snapshot '${snapshot_path}' bootable."
    if [[ ! -e "${snapshot_path}/etc/fstab" ]]; then
        echo_msg $WARN "/etc/fstab not found within the snapshot '${snapshot_path}'."
        echo_msg $WARN "It does not seem to be a snapshot of the / subvolume."
        return
    fi
    # Make a backup copy of /etc/fstab in the snapshot.
    local fstab_backup_success=false
    for i in '' $(seq --format '.%g' 1 99); do
        local fstab_backup="/etc/fstab.snapshot.bak$i"
        if [[ ! -e "${snapshot_path}${fstab_backup}" ]]; then
            echo_msg $DEBUG "Copying /etc/fstab to ${fstab_backup} within the snapshot."
            cp -i "${snapshot_path}/etc/fstab" "${snapshot_path}${fstab_backup}" && fstab_backup_success=true
            break
        fi
    done
    if ! ${fstab_backup_success}; then
        echo_msg $WARN "Could not make a copy of /etc/fstab within the snapshot '${snapshot_path}'."
        echo_msg $WARN "Will not try to make that snapshot bootable."
        return
    fi
    echo_msg $DEBUG "Editing /etc/fstab within the snapshot."
    sed -i -e "/\(subvol=\)${original_subvol_name//\//\\\/}\(,\|\s\)/,\${s//\1${new_subvol_name//\//\\\/}\2/;b};\$q1" "${snapshot_path}/etc/fstab"
    if [[ $? -eq 0 ]]; then
        echo_msg $INFO "It should now be possible to use the snapshot at '${snapshot_path}' as the / subvolume during boot."
        echo_msg $INFO "This requires an appropriate kernel parameter, such as 'rootflags=subvol=${new_subvol_name}'."
        echo_msg $INFO "A copy of /etc/fstab has been saved to ${fstab_backup} within the snapshot."
    else
        echo_msg $WARN "Could not replace the root subvolume in /etc/fstab within the snapshot '${snapshot_path}'."
        echo_msg $WARN "That snapshot is not bootable."
    fi
}


function cleanup() {
    # usage: cleanup
    # Cleans up any temporary directories and mounts.
    if [[ -n "${device}" && -n "${tmpdir}" ]]; then
        # If $device and $tmpdir is set, mounting $device was attempted, but not necessarily successful.
        # As $source_subvol_path is set after mounting, umount is needed iff $source_subvol_path is set.
        if [[ -n "${source_subvol_path}" ]]; then
            echo_msg $DEBUG "Unmounting ${device}."
            umount "${tmpdir}/btrfs" || echo_msg $WARN "Could not unmount temporary mount point '${tmpdir}/btrfs'."
        fi
        echo_msg $DEBUG "Removing temporary mount point '${tmpdir}'."
        rmdir -- "${tmpdir}/btrfs" || echo_msg $WARN "Could not remove temporary mount point '${tmpdir}/btrfs'."
        rmdir -- "${tmpdir}" || echo_msg $WARN "Could not remove temporary directory '${tmpdir}'."
    else
        if ${mount_source}; then
            echo_msg $DEBUG "Unmounting ${source_subvol_path} again."
            umount "${source_subvol_path}" || echo_msg $WARN "Could not unmount '${source_subvol_path}'."
        fi
        if ${mount_snapshots}; then
            echo_msg $DEBUG "Unmounting ${snapshot_subvol_path} again."
            umount "${snapshot_subvol_path}" || echo_msg $WARN "Could not unmount '${snapshot_subvol_path}'."
        fi
    fi
}


#
# Parse the command line parameters.
#

mount_source=false
mount_snapshots=false

alias=''
device=''
read_only=false
time_format='%Y-%m-%d_%H:%M'
loglevel=$INFO
if [[ -t 2 ]]; then
    colour=true
else
    colour=false
fi

# This loop handles option arguments, i.e. those starting with - or --
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --alias)
            alias="$2"
            shift
            ;;
        --alias=*)
            alias="${1#*=}"
            shift
            ;;
        -d|--device)
            device="$2"
            shift
            ;;
        -d=*,--device=*)
            device="${1#*=}"
            ;;
        -r|--read-only)
            read_only=true
            ;;
        -f|--time-format)
            time_format="$2"
            shift
            ;;
        -f=*|--time-format=*)
            time_format="${1#*=}"
            ;;
        --colour|--color)
            colour=true
            ;;
        --no-colour|--no-color)
            colour=false
            ;;
        -v|--verbose)
            loglevel=$((loglevel + 1))
            ;;
        -q|--quiet)
            loglevel=$((loglevel - 1))
            [[ "${loglevel}" -lt 0 ]] && loglevel=0
            ;;
        --)
            # All arguments after -- are considered non-options. These are parsed below.
            shift
            break
            ;;
        -*)
            echo "Unknown option '$1'."
            exit 1
            ;;
        *)
            # Non-option argument. These are parsed below.
            break
            ;;
    esac
    shift
done

# Handle positional arguments.
if [[ $# -lt 3 || $# -gt 4 ]]; then
    usage
    exit 1
fi

if [[ -z "${device}" ]]; then
    source_subvol_path="$1"
    snapshot_subvol_path="$2"
else
    source_subvol_name="$1"
    snapshot_subvol_name="$2"
fi
tag="$3"
keep=${4:-0}

#
# Check for root privileges.
#

if [[ "${EUID}" -ne 0 ]]; then
    die 2 'This script needs root privileges.'
fi

#
# Mount the device/subvolumes, if necessary.
#

if [[ -n "${device}" ]]; then
    # Create temporary directory and mount the device there.
    echo_msg $DEBUG "Mounting ${device} to a temporary mount point."
    tmpdir="$(mktemp -d -p "${TMPDIR:/tmp}" btrshot-XXXXXX)"
    chmod 700 -- "${tmpdir}"
    mkdir -- "${tmpdir}/btrfs" || die 16 "Could not create temporary mount point '${tmpdir}/btrfs'."
    mount -t btrfs -o noatime "${device}" "${tmpdir}/btrfs" || die 17 "Could not mount ${device} as btrfs."
    source_subvol_path="${tmpdir}/btrfs/${source_subvol_name}"
    snapshot_subvol_path="${tmpdir}/btrfs/${snapshot_subvol_name}"
else
    # Make sure the subvolumes are mounted.
    mount_source=true
    mount_snapshots=true
    while read -r -a line; do
        # Convert octal escape sequences in the path.
        mountpoint="$(printf '%b' "${line[1]}")"
        # Check if the current line references the source subvolume.
        if [[ "${mountpoint}" == "${source_subvol_path}" ]]; then
            echo_msg $DEBUG "${source_subvol_path} is currently mounted."
            mount_source=false
        fi
        # Check if the current line references the snapshots subvolume.
        if [[ "${mountpoint}" == "${snapshot_subvol_path}" ]]; then
            echo_msg $DEBUG "${snapshot_subvol_path} is currently mounted."
            mount_snapshots=false
        fi
    done < /proc/self/mounts
    # Mount the subvolumes according to /etc/fstab if they are not already mounted.
    if ${mount_source}; then
        echo_msg $DEBUG "Mounting ${source_subvol_path}."
        mount "${source_subvol_path}" || die 18 "Could not mount source subvolume at '${source_subvol_path}'."
    fi
    if ${mount_snapshots}; then
        echo_msg $DEBUG "Mounting ${snapshot_subvol_path}."
        mount "${snapshot_subvol_path}" || die 19 "Could not mount snapshot subvolume at '${snapshot_subvol_path}'."
    fi
    # Get the name of the source and snapshot subvolumes.
    echo_msg $DEBUG "Getting the names of the subvolumes."
    while read -r -a line; do
        # Convert octal escape sequences in the path.
        mountpoint="$(printf '%b' "${line[4]}")"
        if [[ "${mountpoint}" == "${source_subvol_path}" ]]; then
            source_subvol_name="$(basename -- "$(printf '%b' "${line[3]}")")"
        fi
        if [[ "${mountpoint}" == "${snapshot_subvol_path}" ]]; then
            snapshot_subvol_name="$(basename -- "$(printf '%b' "${line[3]}")")"
        fi
    done < /proc/self/mountinfo
    if [[ -z "${source_subvol_name}" ]]; then
        echo_msg $WARN "Could not get name of the subvolume at '${source_subvol_path}'. Assuming 'root'."
        source_subvol_name='root'
    fi
    if [[ -z "${snapshot_subvol_name}" ]]; then
        echo_msg $WARN "Could not get name of the subvolume at '${snapshot_subvol_path}'. Assuming no name."
        snapshot_subvol_name=''
    fi
fi

#
# Set helpful variables.
#

timestamp="$(date "+${time_format}")"
snapshot_name="${snapshot_subvol_name}/${tag}/${source_subvol_name#/}_${timestamp}"
snapshot_path="${snapshot_subvol_path}/${tag}/${source_subvol_name#/}_${timestamp}"

#
# Make a snapshot.
#

echo_msg $DEBUG "Creating tag directory '${tag}' if necessary."
mkdir -p -- "${snapshot_subvol_path}/${tag}"
if [[ -e "${snapshot_path}" ]]; then
    die 3 "Target snapshot '${snapshot_path}' exists."
fi
${read_only} && opts='-r' || opts=''
echo_msg $DEBUG "Making snapshot of the subvol at '${source_subvol_path}'."
output="$(btrfs subvolume snapshot ${opts} "${source_subvol_path}" "${snapshot_path}")"
if [[ $? -ne 0 ]]; then
    echo "${output}"
    die 4 "btrfs could not create snapshot."
fi

if [[ -n "${alias}" ]]; then
    if [[ -z "${alias##*/*}" ]]; then
        # $alias contains a /, interpret it as a path
        alias_path="${snapshot_subvol_path}/${alias}"
        alias_name="${snapshot_subvol_name}/${alias}"
    else
        # $alias does not contain a /, interpret it as a name
        alias_path="${snapshot_subvol_path}/${tag}/${alias}"
        alias_name="${snapshot_subvol_name}/${tag}/${alias}"
    fi
    # remove the existing snapshot with the given name, if there is one
    if [[ -e "${alias_path}" ]]; then
        echo_msg $DEBUG "Deleting snapshot '${alias_path}'."
        output="$(btrfs subvolume delete "${alias_path}")"
        if [[ $? -ne 0 ]]; then
            echo "${output}"
            die 5 "Could not delete snapshot '${alias_path}'."
        fi
    fi
    # create a snapshot of the snapshot we just created
    output="$(btrfs subvolume snapshot ${opts} "${snapshot_path}" "${alias_path}")"
    if [[ $? -ne 0 ]]; then
        echo "${output}"
        die 6 "btrfs could not create snapshot."
    fi

    # make the alias snapshot bootable
    if ! ${read_only} && [[ "${source_subvol_path}" == '/' ]]; then
        make_bootable "${snapshot_path}" "${source_subvol_name}" "${alias_name}"
    fi
fi

# make the original snapshot bootable
if ! ${read_only} && [[ "${source_subvol_path}" == '/' ]]; then
    make_bootable "${snapshot_path}" "${source_subvol_name}" "${snapshot_name}"
fi

#
# Remove old snapshots.
#

if [[ "${keep}" -gt 0 ]]; then
    echo_msg $DEBUG "Deleting old snapshots, keeping up to ${keep}."
    # Get the snapshots in the tag directory, sort them by their last modification time and remove all but the latest $keep.
    # FIXME: the following will delete snapshots of other subvolumes if this subvolume's name is a prefix of their name...
    find "${snapshot_subvol_path}/${tag}" -mindepth 1 -maxdepth 1 -type d -name "${source_subvol_name#/}_*" -printf '%T@:%p\n' | sort -n | cut -d: -f2- | head -n "-${keep}" | while read -r path; do
        echo_msg $DEBUG "Deleting snapshot '${path}'."
        output="$(btrfs subvolume delete "${path}")"
        if [[ $? -ne 0 ]]; then
            echo "${output}"
            die 7 "Could not delete snapshot '${path}'."
        fi
    done
fi

#
# Clean up.
#

cleanup
