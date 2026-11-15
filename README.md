# OpenStick MSM8916 — Ép xung 1.402 GHz + Hardware DVFS (1 File Duy Nhất)

Script Bash + `perl-base` gọn nhẹ chạy **trực tiếp trên que USB 4G OpenStick (Snapdragon 410 / MSM8916)** chạy Debian kernel `5.15.0-handsomekernel+` (`UFI001C`, `UFI003`, `UZ801`, `JZ0145`, ...), giúp nâng xung tối đa từ `998.4 MHz` lên **`1.402 GHz`** kèm **Hardware DVFS (`vdd-apc` / Buck S2)** tự hạ áp khi nhàn rỗi và tăng áp khi tải nặng.

> **Không cần máy tính cài `python3` / `dtc` / `abootimg` và không cần mạng khi patch** — chỉ cần `bash`, `perl`, `gzip`, `dd`, `sha256sum` vốn đã có sẵn trong Debian OpenStick.

---

## Tính năng & Cơ chế an toàn

1. **Tự động sao lưu trước khi sửa**: Dumps đúng dung lượng Android `boot.img` đang chạy lưu vào `/root/boot_stock_backup.img` (kèm file `.sha256`). Không ghi đè nếu file backup đã tồn tại.
2. **Giữ nguyên phần cứng từng dòng que**: Đọc trực tiếp phân vùng boot (`/dev/disk/by-partlabel/boot` hoặc `/dev/mmcblk0p12`), giữ nguyên ramdisk và các node GPIO/LED/modem trong DTB của chính máy bạn.
3. **Chống mất Wi-Fi sau 30 giây**: Kiểm tra đúng chữ ký relocation của kernel `5.15.0-handsomekernel+` (`0xdd6880`, `0xdd8bf0`, `0xa031c8..0xa031f0`) trước khi patch cô lập Buck `S2` (`vdd-apc`) trong `Image`. Nếu không phải đúng nhân này, script sẽ **dừng an toàn ngay lập tức**.
4. **Cập nhật DTB chuẩn Hardware DVFS**:
   - Thêm/cập nhật `/soc/spmi@200f000/pmic@1/regulators/s2` (`vdd-apc`, `1.05V – 1.375V`, `regulator-always-on`) và gắn `cpu-supply` cho `/cpus/cpu@0`.
   - Cập nhật bảng `/cpu-opp-table` lên đến mức xung mục tiêu.
5. **Xác minh sau khi flash**: Kiểm tra kích thước phân vùng và đọc ngược eMMC so khớp `SHA-256` sau khi ghi.

---

## Cách tải & chạy nhanh trên que

Đăng nhập que bằng quyền `root` (qua SSH / Terminal trên Cockpit / ADB Shell):

### Cách 1: Tải trực tiếp trên que (nếu que đang có Internet)
> Lưu ý: Debian OpenStick mặc định chưa có sẵn `curl`/`wget`, chỉ cần cài nhanh `curl` trước:

```bash
apt-get update && apt-get install -y curl
curl -fsSLO https://raw.githubusercontent.com/NguyenPhat-NT/openstick-msm8916-oc-1.4ghz/main/msm8916_oc_1.4ghz.sh
bash msm8916_oc_1.4ghz.sh
```

### Cách 2: Chép từ máy tính sang que (không cần que có mạng)
Tải file [`msm8916_oc_1.4ghz.sh`](https://raw.githubusercontent.com/NguyenPhat-NT/openstick-msm8916-oc-1.4ghz/main/msm8916_oc_1.4ghz.sh) về máy tính, rồi chép sang que:

- **Qua ADB:**
  ```bash
  adb push msm8916_oc_1.4ghz.sh /root/
  adb shell "bash /root/msm8916_oc_1.4ghz.sh"
  ```
- **Qua SCP / SSH (mặc định IP `192.168.68.1`):**
  ```bash
  scp msm8916_oc_1.4ghz.sh root@192.168.68.1:/root/
  ssh root@192.168.68.1
  bash /root/msm8916_oc_1.4ghz.sh
  ```

---

## Các tùy chọn dòng lệnh

```bash
# Chạy tương tác mặc định -> 1.402 GHz @ 1.3750V
bash msm8916_oc_1.4ghz.sh

# Chạy tự động hoàn toàn (không hỏi xác nhận, tự reboot sau 3 giây)
bash msm8916_oc_1.4ghz.sh -y

# Hạ bớt mức xung nếu chip nóng hoặc silicon không ổn định ở 1.402 GHz:
bash msm8916_oc_1.4ghz.sh --freq 1.36   # 1363.2 MHz @ 1.3625V
bash msm8916_oc_1.4ghz.sh --freq 1.25   # 1248.0 MHz @ 1.3250V
bash msm8916_oc_1.4ghz.sh --freq 1.21   # 1209.6 MHz @ 1.3125V
bash msm8916_oc_1.4ghz.sh --freq 1.15   # 1152.0 MHz @ 1.2750V
bash msm8916_oc_1.4ghz.sh --freq 1.09   # 1094.4 MHz @ 1.2250V

# Khôi phục lại boot gốc từ /root/boot_stock_backup.img:
bash msm8916_oc_1.4ghz.sh --restore

# Patch file boot.img ngoại tuyến (không đụng vào eMMC của máy):
bash msm8916_oc_1.4ghz.sh --in boot_stock.img --out boot_oc.img
```

Xem toàn bộ cờ hỗ trợ (`--backup`, `--dev`, `--no-reboot`, ...):
```bash
bash msm8916_oc_1.4ghz.sh --help
```

---

## Bảng OPP Xung / Điện áp (`vdd-apc`)

| Tần số | Điện áp (`vdd-apc`) | Cờ `--freq` tối đa |
| --- | --- | --- |
| `200.0 MHz` | `1.0500 V` | *(nấc nền)* |
| `400.0 MHz` | `1.0500 V` | *(nấc nền)* |
| `800.0 MHz` | `1.1500 V` | *(nấc nền)* |
| `998.4 MHz` | `1.1500 V` | *(stock gốc)* |
| `1094.4 MHz` | `1.2250 V` | `--freq 1.09` |
| `1152.0 MHz` | `1.2750 V` | `--freq 1.15` |
| `1209.6 MHz` | `1.3125 V` | `--freq 1.21` |
| `1248.0 MHz` | `1.3250 V` | `--freq 1.25` |
| `1363.2 MHz` | `1.3625 V` | `--freq 1.36` |
| `1401.6 MHz` | `1.3750 V` | `--freq 1.40` *(mặc định)* |

---

## Kiểm tra lại sau khi reboot

```bash
# Xem tất cả các nấc xung đang bật
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies

# Xem xung tối đa và xung hiện tại
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq

# Xem điện áp vdd-apc theo thời gian thực
grep -H . /sys/class/regulator/regulator.*/name | grep vdd-apc
cat /sys/class/regulator/regulator.1/microvolts
```

> **Lưu ý tản nhiệt:** Chạy `1.402 GHz` tải nặng liên tục sẽ sinh nhiệt cao hơn stock `998 MHz`. Nên gắn thêm tản nhiệt nhôm/pad tản nhiệt nếu chạy full load 24/7, hoặc dùng `--freq 1.36` / `1.21` để cân bằng nhiệt độ.
