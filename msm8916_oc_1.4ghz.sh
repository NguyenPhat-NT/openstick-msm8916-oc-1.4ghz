#!/usr/bin/env bash
# ==============================================================================
# MSM8916 / OpenStick (5.15.0-handsomekernel+) Overclock + Hardware DVFS Tool
# Safe all-in-one script: zero external dependencies (Bash + perl-base + gzip)
#
# What it does:
#   1. Auto-backups your current boot partition to /root/boot_stock_backup.img
#   2. Extracts your dongle's own Image.gz + DTB + ramdisk (keeps board GPIOs)
#   3. Patches Buck S2 regulator relocations in Image (prevents Wi-Fi drop @30s)
#   4. Adds Hardware DVFS (vdd-apc / Buck S2) & OPP table up to target freq
#   5. Repacks boot.img, flashes partition, verifies SHA-256 readback
#
# Usage:
#   bash msm8916_oc_1.4ghz.sh                  # Interactive -> 1.402 GHz (1.375V)
#   bash msm8916_oc_1.4ghz.sh -y               # Non-interactive + auto reboot
#   bash msm8916_oc_1.4ghz.sh --freq 1.36      # Lower bin if silicone unstable
#   bash msm8916_oc_1.4ghz.sh --restore        # Restore stock boot backup
# ==============================================================================

set -euo pipefail

VERSION="1.0.0"
DEFAULT_BACKUP="/root/boot_stock_backup.img"
DEFAULT_FREQ="1.40"

TARGET_FREQ="$DEFAULT_FREQ"
BOOT_DEV=""
BACKUP_FILE="$DEFAULT_BACKUP"
IN_FILE=""
OUT_FILE=""
DO_RESTORE=0
ASSUME_YES=0
NO_REBOOT=0

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[X] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
MSM8916 OpenStick Overclock + Hardware DVFS (1.402 GHz / vdd-apc)

Usage:
  bash msm8916_oc_1.4ghz.sh [options]

Options:
  --freq <val>     Muc xung toi da:
                     1.40  = 1401.6 MHz @ 1.3750V (mac dinh)
                     1.36  = 1363.2 MHz @ 1.3625V (may yeu / mat hon)
                     1.25  = 1248.0 MHz @ 1.3250V
                     1.21  = 1209.6 MHz @ 1.3125V
                     1.15  = 1152.0 MHz @ 1.2750V
                     1.09  = 1094.4 MHz @ 1.2250V
  --restore        Khoi phuc lai boot goc tu /root/boot_stock_backup.img
  --backup <path>  Duong dan file backup (mac dinh: /root/boot_stock_backup.img)
  --dev <blockdev> Chi dinh partition boot (mac dinh: tu tim by-partlabel/boot hoac mmcblk0p12)
  -y, --yes        Tu dong dong y khong hoi lai
  --no-reboot      Khong khoi dong lai sau khi flash
  --in <file>      Che do offline: doc tu file boot.img thay vi flash vao may
  --out <file>     Che do offline: ghi ket qua ra file (dung kem --in)
  -h, --help       Hien thi huong dan nay
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --freq)
            [[ $# -ge 2 ]] || die "Thieu gia tri sau --freq"
            TARGET_FREQ="$2"
            shift 2
            ;;
        --restore)
            DO_RESTORE=1
            shift
            ;;
        --backup)
            [[ $# -ge 2 ]] || die "Thieu duong dan sau --backup"
            BACKUP_FILE="$2"
            shift 2
            ;;
        --dev)
            [[ $# -ge 2 ]] || die "Thieu duong dan sau --dev"
            BOOT_DEV="$2"
            shift 2
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        --no-reboot)
            NO_REBOOT=1
            shift
            ;;
        --in)
            [[ $# -ge 2 ]] || die "Thieu duong dan sau --in"
            IN_FILE="$2"
            shift 2
            ;;
        --out)
            [[ $# -ge 2 ]] || die "Thieu duong dan sau --out"
            OUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Tham so khong hop le: $1 (dung --help de xem cach dung)"
            ;;
    esac
done

case "$TARGET_FREQ" in
    1.40|1.4|1401|1401600|1401600000) TARGET_HZ=1401600000; TARGET_LABEL="1.402 GHz @ 1.3750V" ;;
    1.36|1363|1363200|1363200000)     TARGET_HZ=1363200000; TARGET_LABEL="1.363 GHz @ 1.3625V" ;;
    1.25|1248|1248000|1248000000)     TARGET_HZ=1248000000; TARGET_LABEL="1.248 GHz @ 1.3250V" ;;
    1.21|1210|1209|1209600|1209600000) TARGET_HZ=1209600000; TARGET_LABEL="1.210 GHz @ 1.3125V" ;;
    1.15|1152|1152000|1152000000)     TARGET_HZ=1152000000; TARGET_LABEL="1.152 GHz @ 1.2750V" ;;
    1.09|1094|1094400|1094400000)     TARGET_HZ=1094400000; TARGET_LABEL="1.094 GHz @ 1.2250V" ;;
    *) die "Muc --freq khong ho tro: '$TARGET_FREQ'. Chon 1.40, 1.36, 1.25, 1.21, 1.15, hoac 1.09." ;;
esac

OFFLINE_MODE=0
if [[ -n "$IN_FILE" || -n "$OUT_FILE" ]]; then
    [[ -n "$IN_FILE" && -n "$OUT_FILE" ]] || die "Che do offline can ca --in va --out"
    [[ -f "$IN_FILE" ]] || die "Khong tim thay file dau vao: $IN_FILE"
    OFFLINE_MODE=1
fi

for cmd in perl gzip gunzip dd sha256sum wc sync mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || die "Thieu lenh he thong bat buoc: $cmd"
done

TMP_BASE="/var/tmp"
[[ -d "$TMP_BASE" ]] || TMP_BASE="/tmp"
WORKDIR="$(mktemp -d "${TMP_BASE}/msm8916_oc.XXXXXX")"
cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

detect_boot_dev() {
    if [[ -n "$BOOT_DEV" ]]; then
        [[ -b "$BOOT_DEV" ]] || die "Khong tim thay block device: $BOOT_DEV"
        return 0
    fi
    if [[ -b /dev/disk/by-partlabel/boot ]]; then
        BOOT_DEV="$(readlink -f /dev/disk/by-partlabel/boot)"
    elif [[ -b /dev/mmcblk0p12 ]]; then
        BOOT_DEV="/dev/mmcblk0p12"
    else
        die "Khong tu tim thay phan vung boot! Hay chi dinh bang --dev /dev/mmcblk..."
    fi
}

get_blockdev_bytes() {
    perl -e '
        use strict; use warnings;
        open(my $fh, "<", $ARGV[0]) or die "open $ARGV[0]: $!\n";
        seek($fh, 0, 2) or die "seek: $!\n";
        print tell($fh), "\n";
    ' "$1"
}

ask_confirm() {
    local prompt="$1"
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Khong co terminal tuong tac (TTY). Hay chay lai voi co -y de xac nhan tu dong."
    fi
    printf '%s [y/N]: ' "$prompt"
    local ans=""
    read -r ans || true
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) log "Da huy theo yeu cau nguoi dung."; exit 0 ;;
    esac
}

maybe_reboot() {
    if [[ "$NO_REBOOT" -eq 1 ]]; then
        ok "Da bo qua khoi dong lai (--no-reboot). Hay tu 'reboot' de ap dung."
        return 0
    fi
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        ok "Dang khoi dong lai sau 3 giay..."
        sleep 3
        reboot
        return 0
    fi
    if [[ -t 0 ]]; then
        printf 'Khoi dong lai ngay bay gio de kich hoat? [Y/n]: '
        local ans=""
        read -r ans || true
        case "$ans" in
            n|N|no|NO)
                log "Hay tu chay lenh 'reboot' sau."
                ;;
            *)
                ok "Dang khoi dong lai..."
                sleep 1
                reboot
                ;;
        esac
    else
        ok "Vui long chay lenh 'reboot' de ap dung thay doi."
    fi
}

flash_and_verify() {
    local img_path="$1"
    local dev_path="$2"
    local img_size part_size img_sha read_sha

    img_size="$(wc -c < "$img_path")"
    part_size="$(get_blockdev_bytes "$dev_path")"
    [[ "$img_size" -gt 1048576 ]] || die "File boot qua nho ($img_size bytes), huy flash!"
    [[ "$img_size" -le "$part_size" ]] || die "File boot ($img_size B) lon hon phan vung $dev_path ($part_size B)!"

    img_sha="$(sha256sum "$img_path" | awk '{print $1}')"
    log "Dang ghi $img_size bytes vao $dev_path..."
    dd if="$img_path" of="$dev_path" bs=1048576 conv=fsync status=none
    sync

    log "Dang doc nguoc kiem tra SHA-256 tren eMMC..."
    dd if="$dev_path" of="$WORKDIR/verify_readback.img" bs=1048576 count="$(( (img_size + 1048575) / 1048576 ))" status=none
    perl -e 'truncate($ARGV[0], $ARGV[1]) or die $!' "$WORKDIR/verify_readback.img" "$img_size"
    read_sha="$(sha256sum "$WORKDIR/verify_readback.img" | awk '{print $1}')"

    [[ "$img_sha" == "$read_sha" ]] || die "LOI NGHIEM TRONG: SHA-256 doc lai khong khop ($read_sha != $img_sha)! KHONG REBOOT, hay --restore lai ngay!"
    ok "Xac minh flash thanh cong! SHA-256: $img_sha"
}

run_perl_patch() {
    local boot_in="$1"
    local boot_out="$2"
    local target_hz="$3"
    local workdir="$4"

    perl - "$boot_in" "$boot_out" "$target_hz" "$workdir" <<'PERL_EOF'
use strict;
use warnings;
no warnings 'portable';
use Config;

die "Perl khong ho tro so nguyen 64-bit (uvsize=$Config{uvsize})\n" if $Config{uvsize} < 8;

my ($boot_in, $boot_out, $target_hz, $workdir) = @ARGV;
$target_hz = int($target_hz);

sub read_file_bin {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "Khong mo duoc $path: $!\n";
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

sub write_file_bin {
    my ($path, $data) = @_;
    open(my $fh, '>:raw', $path) or die "Khong ghi duoc $path: $!\n";
    print {$fh} $data or die "Loi ghi $path: $!\n";
    close($fh);
}

sub align_val {
    my ($val, $align) = @_;
    my $rem = $val % $align;
    return $rem ? ($val + $align - $rem) : $val;
}

# --- 1. Parse Android boot.img ---
my $boot = read_file_bin($boot_in);
die "File boot qua ngan\n" if length($boot) < 2048;

my ($magic, $k_sz, $k_addr, $r_sz, $r_addr, $s_sz, $s_addr, $tags_addr, $psize, $dt_sz, $unused)
    = unpack('a8 V10', substr($boot, 0, 48));

die "Khong phai Android boot.img hop le (thieu magic ANDROID!)\n" if $magic ne 'ANDROID!';
die "Page size khong hop le: $psize\n" if $psize < 2048 || ($psize & ($psize - 1)) != 0;

my $k_off  = $psize;
my $r_off  = $k_off  + align_val($k_sz,  $psize);
my $s_off  = $r_off  + align_val($r_sz,  $psize);
my $dt_off = $s_off  + align_val($s_sz,  $psize);
my $orig_total = $dt_off + align_val($dt_sz, $psize);

die "File boot bi cat cut (can $orig_total bytes, co " . length($boot) . " bytes)\n"
    if length($boot) < $orig_total;

my $hdr_page = substr($boot, 0, $psize);
my $kblob    = substr($boot, $k_off,  $k_sz);
my $ramdisk  = substr($boot, $r_off,  $r_sz);
my $second   = $s_sz  ? substr($boot, $s_off,  $s_sz)  : '';
my $dt_blob  = $dt_sz ? substr($boot, $dt_off, $dt_sz) : '';

# --- 2. Locate appended DTB inside kernel blob ---
my $fdt_magic = pack('N', 0xd00dfeed);
my $dtb_off = -1;
my $search_pos = 0;

while ((my $idx = index($kblob, $fdt_magic, $search_pos)) >= 0) {
    if ($idx + 40 <= length($kblob)) {
        my ($m, $tsize, $o_struct, $o_str, $o_rsv, $ver, $lver, $cpuid, $s_str, $s_struct)
            = unpack('N10', substr($kblob, $idx, 40));
        if ($ver == 17 && $tsize >= 40 && $idx + $tsize == length($kblob)
            && $o_struct >= 40 && $o_str >= $o_struct + $s_struct
            && $o_str + $s_str <= $tsize)
        {
            $dtb_off = $idx;
            last;
        }
    }
    $search_pos = $idx + 1;
}

die "Khong tim thay DTB dinh kem (appended DTB) o cuoi kernel Image.gz!\n" if $dtb_off < 0;

my $gz_data = substr($kblob, 0, $dtb_off);
my $dtb_raw = substr($kblob, $dtb_off);

die "Kernel khong phai gzip (thieu header 1f 8b 08)\n"
    if substr($gz_data, 0, 3) ne "\x1f\x8b\x08";

printf "[*] Phat hien boot.img: page=%d, kernel+dtb=%d B (gz=%d B, dtb=%d B), ramdisk=%d B\n",
    $psize, $k_sz, length($gz_data), length($dtb_raw), $r_sz;

# --- 3. Decompress Image.gz -> Image and patch Buck S2 relocations ---
my $gz_path  = "$workdir/Image.gz";
my $img_path = "$workdir/Image";
my $new_gz   = "$workdir/Image_new.gz";

write_file_bin($gz_path, $gz_data);
my $rc = system('sh', '-c', qq{gzip -dc "\$1" > "\$2"}, 'sh', $gz_path, $img_path);
die "Giai nen Image.gz that bai (exit $rc)\n" if $rc != 0;

my $image = read_file_bin($img_path);
printf "[*] Giai nen Image thanh cong: %d bytes\n", length($image);

die sprintf("Kernel Image kich thuoc khac (%d bytes). Chi ho tro kernel OpenStick 5.15.0-handsomekernel+!\n", length($image))
    if length($image) < 0xdd8c08;

my ($r1_off, $r1_info, $r1_add) = unpack('Q<3', substr($image, 0xdd6880, 24));
my ($r2_off, $r2_info, $r2_add) = unpack('Q<3', substr($image, 0xdd8bf0, 24));
my $z_region = substr($image, 0xa031c8, 40);

my $stock_z  = ("\x00" x 8) . "\x00\x1a" . ("\x00" x 30);
my $zeros_24 = "\x00" x 24;
my $zeros_40 = "\x00" x 40;

if ($r1_off == 0xffff800010a00ac0 && $r1_info == 0x403 && $r1_add == 0xffff800010a03178
    && $r2_off == 0xffff800010a031c8 && $r2_info == 0x403 && $r2_add == 0xffff800010c1a1a0
    && ($z_region eq $stock_z || $z_region eq $zeros_40))
{
    substr($image, 0xdd6890, 8, pack('Q<', 0xffff800010a031a0));
    substr($image, 0xdd8bf0, 24, $zeros_24);
    substr($image, 0xa031c8, 40, $zeros_40);
    print "[+] Da patch Buck S2 isolation trong Image (chong tat Wi-Fi sau 30s).\n";
}
elsif ($r1_off == 0xffff800010a00ac0 && $r1_info == 0x403 && $r1_add == 0xffff800010a031a0
    && substr($image, 0xdd8bf0, 24) eq $zeros_24
    && $z_region eq $zeros_40)
{
    print "[*] Image da duoc patch Buck S2 tu truoc (giu nguyen).\n";
}
else {
    die sprintf(
        "Kernel Image khong khop chu ky relocation cua 5.15.0-handsomekernel+!\n"
      . "    rel1=(0x%x, 0x%x, 0x%x) rel2=(0x%x, 0x%x, 0x%x)\n"
      . "    Dung lai de bao ve may khoi mat Wi-Fi hoac treo boot.\n",
      $r1_off, $r1_info, $r1_add, $r2_off, $r2_info, $r2_add
    );
}

write_file_bin($img_path, $image);
$rc = system('sh', '-c', qq{gzip -9 -n -c "\$1" > "\$2"}, 'sh', $img_path, $new_gz);
die "Nen lai Image.gz that bai (exit $rc)\n" if $rc != 0;
my $new_gz_data = read_file_bin($new_gz);
printf "[*] Nen lai Image.gz: %d bytes\n", length($new_gz_data);

# --- 4. Pure-Perl FDT (v17) Parser, Editor & Serializer ---
my ($fdt_m, $fdt_tot, $off_struct, $off_str, $off_rsv, $fdt_ver, $fdt_lver, $boot_cpuid, $sz_str, $sz_struct)
    = unpack('N10', substr($dtb_raw, 0, 40));

my $mem_rsv_raw = substr($dtb_raw, $off_rsv, $off_struct - $off_rsv);
my $struct_buf  = substr($dtb_raw, $off_struct, $sz_struct);
my $str_buf     = substr($dtb_raw, $off_str, $sz_str);

sub get_cstr {
    my ($buf, $off) = @_;
    my $nul = index($buf, "\x00", $off);
    die "Chuoi C-string khong ket thuc bang NUL tai offset $off\n" if $nul < 0;
    return substr($buf, $off, $nul - $off);
}

my $pos = 0;
my @stack;
my $root_node = undef;

while ($pos < length($struct_buf)) {
    my $tok = unpack('N', substr($struct_buf, $pos, 4));
    $pos += 4;
    if ($tok == 1) { # FDT_BEGIN_NODE
        my $nul = index($struct_buf, "\x00", $pos);
        die "FDT_BEGIN_NODE loi ten node\n" if $nul < 0;
        my $name = substr($struct_buf, $pos, $nul - $pos);
        $pos = align_val($nul + 1, 4);
        my $node = { name => $name, props => [], children => [] };
        if (@stack) {
            push @{$stack[-1]->{children}}, $node;
        }
        push @stack, $node;
        $root_node = $node unless defined $root_node;
    }
    elsif ($tok == 2) { # FDT_END_NODE
        die "FDT_END_NODE du thua\n" unless @stack;
        pop @stack;
    }
    elsif ($tok == 3) { # FDT_PROP
        my ($plen, $pnameoff) = unpack('N2', substr($struct_buf, $pos, 8));
        $pos += 8;
        my $pval = substr($struct_buf, $pos, $plen);
        $pos = align_val($pos + $plen, 4);
        my $pname = get_cstr($str_buf, $pnameoff);
        die "FDT_PROP nam ngoai node\n" unless @stack;
        push @{$stack[-1]->{props}}, [ $pname, $pval ];
    }
    elsif ($tok == 4) { # FDT_NOP
        next;
    }
    elsif ($tok == 9) { # FDT_END
        last;
    }
    else {
        die sprintf("FDT token khong hop le: %d tai offset %d\n", $tok, $pos - 4);
    }
}

die "FDT root khong hop le\n" unless defined $root_node;

sub find_by_path {
    my ($node, $path) = @_;
    my @segs = grep { length($_) > 0 } split('/', $path);
    my $cur = $node;
    for my $seg (@segs) {
        my $found;
        for my $ch (@{$cur->{children}}) {
            if ($ch->{name} eq $seg) {
                $found = $ch;
                last;
            }
        }
        return undef unless defined $found;
        $cur = $found;
    }
    return $cur;
}

sub find_by_compat {
    my ($node, $compat_substr) = @_;
    for my $p (@{$node->{props}}) {
        if ($p->[0] eq 'compatible' && index($p->[1], $compat_substr) >= 0) {
            return $node;
        }
    }
    for my $ch (@{$node->{children}}) {
        my $res = find_by_compat($ch, $compat_substr);
        return $res if defined $res;
    }
    return undef;
}

sub get_prop {
    my ($node, $name) = @_;
    for my $p (@{$node->{props}}) {
        return $p->[1] if $p->[0] eq $name;
    }
    return undef;
}

sub set_prop {
    my ($node, $name, $val) = @_;
    for my $p (@{$node->{props}}) {
        if ($p->[0] eq $name) {
            $p->[1] = $val;
            return;
        }
    }
    push @{$node->{props}}, [ $name, $val ];
}

# Collect all existing phandles to avoid collisions
my %used_phandles;
my $max_phandle = 0;
sub scan_phandles {
    my ($node) = @_;
    for my $p (@{$node->{props}}) {
        if (($p->[0] eq 'phandle' || $p->[0] eq 'linux,phandle') && length($p->[1]) == 4) {
            my $ph = unpack('N', $p->[1]);
            $used_phandles{$ph} = 1;
            $max_phandle = $ph if $ph > $max_phandle;
        }
    }
    scan_phandles($_) for @{$node->{children}};
}
scan_phandles($root_node);

sub find_by_name {
    my ($node, $target) = @_;
    return $node if $node->{name} eq $target;
    for my $ch (@{$node->{children}}) {
        my $res = find_by_name($ch, $target);
        return $res if defined $res;
    }
    return undef;
}

my $regulators = find_by_path($root_node, '/soc/spmi@200f000/pmic@1/regulators')
              // find_by_compat($root_node, 'qcom,pm8916-regulators');

if (!defined $regulators) {
    my $pmic1 = find_by_path($root_node, '/soc/spmi@200f000/pmic@1')
             // find_by_name($root_node, 'pmic@1')
             // die "Khong tim thay node pmic\@1 hoac pm8916 regulators trong DTB!\n";
    $regulators = {
        name     => 'regulators',
        props    => [ [ 'compatible', "qcom,pm8916-regulators\x00" ] ],
        children => [],
    };
    push @{$pmic1->{children}}, $regulators;
}

my $cpu0 = find_by_path($root_node, '/cpus/cpu@0')
        // die "Khong tim thay node /cpus/cpu\@0 trong DTB!\n";

my $opp_table = find_by_path($root_node, '/cpu-opp-table')
             // die "Khong tim thay node /cpu-opp-table trong DTB!\n";

# Upsert child s2 inside regulators
my $s2_node;
for my $ch (@{$regulators->{children}}) {
    if ($ch->{name} eq 's2') {
        $s2_node = $ch;
        last;
    }
}
if (!defined $s2_node) {
    $s2_node = { name => 's2', props => [], children => [] };
    push @{$regulators->{children}}, $s2_node;
}

my $s2_phandle;
my $existing_s2_ph = get_prop($s2_node, 'phandle');
if (defined $existing_s2_ph && length($existing_s2_ph) == 4) {
    $s2_phandle = unpack('N', $existing_s2_ph);
} elsif (!$used_phandles{0x9a}) {
    $s2_phandle = 0x9a;
} else {
    $s2_phandle = $max_phandle + 1;
}

set_prop($s2_node, 'regulator-name',          "vdd-apc\x00");
set_prop($s2_node, 'regulator-min-microvolt', pack('N', 1050000));
set_prop($s2_node, 'regulator-max-microvolt', pack('N', 1375000));
set_prop($s2_node, 'regulator-always-on',     '');
set_prop($s2_node, 'phandle',                 pack('N', $s2_phandle));

set_prop($cpu0, 'cpu-supply', pack('N', $s2_phandle));

my @FULL_OPP = (
    [ 200000000,  1050000 ],
    [ 400000000,  1050000 ],
    [ 800000000,  1150000 ],
    [ 998400000,  1150000 ],
    [ 1094400000, 1225000 ],
    [ 1152000000, 1275000 ],
    [ 1209600000, 1312500 ],
    [ 1248000000, 1325000 ],
    [ 1363200000, 1362500 ],
    [ 1401600000, 1375000 ],
);

# Keep any non-opp child if present, replace all opp-* nodes
@{$opp_table->{children}} = grep { $_->{name} !~ /^opp-/ } @{$opp_table->{children}};

my $count_opp = 0;
for my $entry (@FULL_OPP) {
    my ($f_hz, $uv) = @$entry;
    last if $f_hz > $target_hz;
    push @{$opp_table->{children}}, {
        name     => "opp-$f_hz",
        props    => [
            [ 'opp-hz',        pack('N2', 0, $f_hz) ],
            [ 'opp-microvolt', pack('N', $uv)       ],
        ],
        children => [],
    };
    $count_opp++;
}

printf "[+] Da cap nhat DTB: Buck S2 phandle=0x%x (1.05V-1.375V), cpu-supply=0x%x, %d muc OPP (max %d Hz)\n",
    $s2_phandle, $s2_phandle, $count_opp, $target_hz;

# --- Serialize FDT ---
my $out_str    = '';
my %str_offsets;
my $out_struct = '';

sub intern_str {
    my ($s) = @_;
    return $str_offsets{$s} if exists $str_offsets{$s};
    my $off = length($out_str);
    $out_str .= $s . "\x00";
    $str_offsets{$s} = $off;
    return $off;
}

sub pad4 {
    my ($s) = @_;
    my $rem = length($s) % 4;
    return $rem ? ($s . ("\x00" x (4 - $rem))) : $s;
}

sub emit_node {
    my ($node) = @_;
    $out_struct .= pack('N', 1) . pad4($node->{name} . "\x00");
    for my $p (@{$node->{props}}) {
        my ($pname, $pval) = @$p;
        my $noff = intern_str($pname);
        $out_struct .= pack('N3', 3, length($pval), $noff) . pad4($pval);
    }
    emit_node($_) for @{$node->{children}};
    $out_struct .= pack('N', 2);
}

emit_node($root_node);
$out_struct .= pack('N', 9); # FDT_END

my $new_off_rsv    = 40;
my $rsv_padded     = $mem_rsv_raw;
my $new_off_struct = $new_off_rsv + length($rsv_padded);
my $new_sz_struct  = length($out_struct);
my $new_off_str    = $new_off_struct + $new_sz_struct;
my $new_sz_str     = length($out_str);
my $new_tot        = $new_off_str + $new_sz_str;

my $new_fdt_hdr = pack('N10',
    0xd00dfeed, $new_tot, $new_off_struct, $new_off_str, $new_off_rsv,
    17, 16, $boot_cpuid, $new_sz_str, $new_sz_struct
);
my $new_dtb = $new_fdt_hdr . $rsv_padded . $out_struct . $out_str;

# --- 5. Repack Android boot.img ---
my $new_kblob = $new_gz_data . $new_dtb;
my $new_k_sz  = length($new_kblob);

substr($hdr_page, 8, 4, pack('V', $new_k_sz));

sub pad_page {
    my ($buf, $p) = @_;
    my $rem = length($buf) % $p;
    return $rem ? ($buf . ("\x00" x ($p - $rem))) : $buf;
}

my $new_boot = $hdr_page
             . pad_page($new_kblob, $psize)
             . pad_page($ramdisk,   $psize)
             . ($s_sz  ? pad_page($second,  $psize) : '')
             . ($dt_sz ? pad_page($dt_blob, $psize) : '');

write_file_bin($boot_out, $new_boot);
printf "[+] Da dong goi boot.img moi: %d bytes (kernel+dtb=%d B, dtb=%d B)\n",
    length($new_boot), $new_k_sz, length($new_dtb);
PERL_EOF
}

# ==============================================================================
# Main Flow
# ==============================================================================
echo "========================================================================"
echo "  MSM8916 / OpenStick Overclock + Hardware DVFS Tool (v$VERSION)"
echo "========================================================================"

if [[ "$OFFLINE_MODE" -eq 1 ]]; then
    log "Che do OFFLINE: $IN_FILE -> $OUT_FILE ($TARGET_LABEL)"
    run_perl_patch "$IN_FILE" "$OUT_FILE" "$TARGET_HZ" "$WORKDIR"
    ok "Hoan tat file output: $OUT_FILE"
    exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "Vui long chay voi quyen root (vi du: sudo bash $0)"
ARCH="$(uname -m)"
[[ "$ARCH" == "aarch64" ]] || warn "Kien truc may dang la '$ARCH' (khong phai aarch64 OpenStick!)"

detect_boot_dev

if [[ "$DO_RESTORE" -eq 1 ]]; then
    [[ -f "$BACKUP_FILE" ]] || die "Khong tim thay file backup tai: $BACKUP_FILE"
    if [[ -f "${BACKUP_FILE}.sha256" ]]; then
        log "Kiem tra toan ven file backup (${BACKUP_FILE}.sha256)..."
        (cd "$(dirname "$BACKUP_FILE")" && sha256sum -c "$(basename "${BACKUP_FILE}.sha256")") \
            || die "File backup bi hong SHA-256! Huy restore."
    fi
    magic_chk="$(dd if="$BACKUP_FILE" bs=8 count=1 status=none)"
    [[ "$magic_chk" == "ANDROID!" ]] || die "File backup khong phai Android boot.img hop le!"

    echo "  Phan vung boot : $BOOT_DEV"
    echo "  File backup    : $BACKUP_FILE"
    ask_confirm "Xac nhan KHOI PHUC lai boot goc va ghi de $BOOT_DEV?"
    flash_and_verify "$BACKUP_FILE" "$BOOT_DEV"
    maybe_reboot
    exit 0
fi

# Live dump boot partition (exact Android boot.img byte length)
log "Phan vung boot : $BOOT_DEV"
if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq ]]; then
    cur_khz="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo '?')"
    log "Xung max hien tai: ${cur_khz} KHz | Kernel: $(uname -r)"
fi
log "Muc tieu moi   : $TARGET_LABEL ($TARGET_HZ Hz + Hardware DVFS vdd-apc)"

PART_BYTES="$(get_blockdev_bytes "$BOOT_DEV")"
DUMP_MB=$(( PART_BYTES / 1048576 ))
[[ "$DUMP_MB" -gt 64 ]] && DUMP_MB=64
[[ "$DUMP_MB" -lt 1 ]] && die "Kich thuoc phan vung $BOOT_DEV qua nho ($PART_BYTES B)"

RAW_DUMP="$WORKDIR/boot_live_raw.img"
log "Dang doc du lieu boot hien tai tu $BOOT_DEV..."
dd if="$BOOT_DEV" of="$RAW_DUMP" bs=1048576 count="$DUMP_MB" status=none

EXACT_LEN="$(perl -e '
    use strict; use warnings;
    open(my $fh, "<:raw", $ARGV[0]) or die $!;
    read($fh, my $h, 48) == 48 or die "doc header loi\n";
    my ($m, $k, $ka, $r, $ra, $s, $sa, $t, $p, $d) = unpack("a8 V9", $h);
    die "Khong phai Android boot.img\n" if $m ne "ANDROID!";
    my $al = sub { my ($v,$a)=@_; my $rem=$v%$a; $rem ? $v+$a-$rem : $v; };
    print $p + $al->($k,$p) + $al->($r,$p) + $al->($s,$p) + $al->($d,$p), "\n";
' "$RAW_DUMP")"

LIVE_BOOT="$WORKDIR/boot_live.img"
cp "$RAW_DUMP" "$LIVE_BOOT"
perl -e 'truncate($ARGV[0], $ARGV[1]) or die $!' "$LIVE_BOOT" "$EXACT_LEN"
rm -f "$RAW_DUMP"
ok "Da trich xuat boot hien tai: $EXACT_LEN bytes"

# Save stock backup once (never clobber existing backup)
if [[ ! -f "$BACKUP_FILE" ]]; then
    log "Chua co backup -> dang luu ban goc vao $BACKUP_FILE..."
    cp "$LIVE_BOOT" "$BACKUP_FILE"
    (cd "$(dirname "$BACKUP_FILE")" && sha256sum "$(basename "$BACKUP_FILE")" > "${BACKUP_FILE}.sha256")
    sync
    ok "Da sao luu an toan tai: $BACKUP_FILE"
else
    log "Da co san backup tai $BACKUP_FILE (giu nguyen ban goc)."
fi

PATCHED_BOOT="$WORKDIR/boot_oc_patched.img"
run_perl_patch "$LIVE_BOOT" "$PATCHED_BOOT" "$TARGET_HZ" "$WORKDIR"

echo "------------------------------------------------------------------------"
echo "  San sang nap boot moi len: $BOOT_DEV"
echo "  Muc xung toi da         : $TARGET_LABEL"
echo "  Backup de restore       : $BACKUP_FILE"
echo "------------------------------------------------------------------------"
ask_confirm "Ban co chac chan muon flash boot moi vao may khong?"

flash_and_verify "$PATCHED_BOOT" "$BOOT_DEV"
maybe_reboot
