# rtx-3050m-labs

Исследование пределов **NVIDIA RTX 3050 Laptop (GA107M, 4 ГБ GDDR6)** под Linux: Dynamic Boost,
поиск стабильного разгона ядра и памяти, бэкап и прошивка vBIOS. Проверено на ASUS Vivobook Pro 15
M6500QC (плата Board ID 02A6, vBIOS 94.07.5B.00.97, 35/50 W), драйвер 595, Linux Mint 21 / ядро 6.8.

Меню и управление питанием ноутбука целиком: [vivobook-tune](ssh://git@git.coboto.ru:30909/yura/vivobook-tune.git).
Если он установлен, скрипты отсюда работают через его `cpu-tune` и требуют lab-режима со сторожем `hw-lab`.
Без него скрипты ставят частоты сами (через sudo), а за температурой нужно следить вручную.

## Установка

```sh
sudo ./setup.sh    # CUDA, gpu-burn (sm_86), memtest_vulkan, политика D-Bus для nvidia-powerd
```

nvflash скачивается вручную с TechPowerUp (там капча). Для бэкапа подходит любая свежая версия.
Для обхода Board ID нужна именно Linux **5.792.0** (архив `nvflash_5.792_linux.zip`,
SHA256 `bc369185…63bc7e7`) и патчер [nvflashk-linux](https://github.com/y0usaf/nvflashk-linux).
Патчер подключён как submodule в `third_party/`, на проверенном коммите `2fb4719`
(читает файл, меняет 9 байт в двух местах, сверяет SHA256 на входе и выходе, сети и `unsafe` нет):

```sh
git clone --recurse-submodules ssh://git@git.coboto.ru:30909/yura/rtx-3050m-labs.git
unzip nvflash_5.792_linux.zip -d tools/nvflash-5.792
vbios/make-nvflashk tools/nvflash-5.792/x64/nvflash      # нужен Rust (rustup.rs) -> tools/nvflashk
```

Сам nvflash и пропатченный `nvflashk` в репозиторий не входят: это софт NVIDIA.

## Структура

```
oc/          разгон и поиск пределов
  nv-oc            оффсеты частот ядра и памяти через NVML (get, set <core> <mem>)
  gpu-limit-find   потолок ядра: шаги оффсета + gpu-burn с проверкой, телеметрия, перепроверка после сбоя
  gpu-mem-find     потолок памяти: memtest_vulkan, ошибки + пропускная способность (ловит повторы EDC), --cap
vbios/       прошивка видеокарты
  gpu-backup       полный бэкап EEPROM через nvflash, два чтения со сравнением (только из TTY)
  gpu-flash        прошивка с проверками: бэкап, зарядка, ≥50 %, чтение назад (только из TTY)
  gpu-sensor-check датчик мощности следит за нагрузкой? (900 MHz, 10 с, вердикт TRACKS/BROKEN)
  gpu-recovery-mode on|off  загрузка совсем без драйвера NVIDIA, если он виснет на карте
  rom-inspect      сравнение образов: ID чипа, Board ID, subsystem, версия
  make-nvflashk    собирает патчер из third_party/ и делает tools/nvflashk из nvflash 5.792.0
  gpu-dump         дамп через sysfs, только legacy 64 КБ, для восстановления НЕ годится
docs/RECOVERY.md гайд по восстановлению карты после неудачной прошивки
archive/     patch-boardid: неудачный эксперимент, не использовать
third_party/ nvflashk-linux (submodule)
setup.sh     установка инструментов
firmware/    прошивки и бэкапы       (локально, не в git)
tools/       gpu-burn, memtest, nvflash (локально, не в git)
results/     результаты тестов
```

Все команды запускаются из корня репозитория.

> **Что-то пошло не так с прошивкой?** Читай [docs/RECOVERY.md](docs/RECOVERY.md).

## Быстрый старт

```sh
# 1. Dynamic Boost: от сети, профиль performance
echo performance | sudo tee /sys/firmware/acpi/platform_profile
nvidia-smi -q -d POWER | grep -i limit           # Max Power Limit 50 W, под нагрузкой до 50 W

# 2. Потолок ядра (шаг 25 MHz, по 60 с на шаг)
oc/gpu-limit-find --duration 60

# 3. Потолок памяти при выбранном ядре (шаг 250, по 45 с)
oc/gpu-mem-find --core 150 --step 250 --max 3000 --duration 45

# 4. Долгая проверка итоговой пары: 15 мин память, 15 мин вычисления
oc/gpu-mem-find --core 150 --start 2000 --max 2000 --duration 900
sudo oc/nv-oc set 150 2000 && (cd tools/gpu-burn && ./gpu_burn 900)

# Бэкап и прошивка: только из TTY (Ctrl+Alt+F2), драйвер NVIDIA выгружается
sudo vbios/gpu-backup
sudo vbios/gpu-flash firmware/vbios-full-backup.rom tools/nvflashk   # откат на свой бэкап
vbios/gpu-sensor-check                                            # сразу после любой прошивки
```

Оффсеты живут в драйвере и сбрасываются, когда карта засыпает (RTD3) или при перезагрузке.
vivobook-tune ставит их заново автоматически, без него нужно повторить `oc/nv-oc set`.

## Что выяснили

### Dynamic Boost: 35 → 50 W

На Ubuntu `nvidia-powerd` не стартует: политика D-Bus лежит только в документации
(`/usr/share/doc/nvidia-driver-*/nvidia-dbus.conf`, её надо положить в `/etc/dbus-1/system.d/`).
Кроме того, SBIOS ASUS разрешает буст только **от сети** и в профиле **performance**
(`/sys/firmware/acpi/platform_profile`). В лог при этом пишется «disable Dynamic Boost DC controller»:
это про работу от батареи, так и должно быть.

### Разгон

| | 35 W сток | 50 W | 50 W + core +150 / mem +2000 |
|---|---|---|---|
| gpu-burn | 3170 GFLOPS | 3770 GFLOPS | 3910 GFLOPS (15 мин, 85 °C, 0 ошибок) |
| memtest_vulkan | 149 GB/s | 149 GB/s | 173 GB/s (15 мин, 0 ошибок) |

- **Ядро.** +250 проходит gpu-burn, потому что тот упирает карту в лимит мощности, и частота держится около 1550 MHz.
  При лёгкой нагрузке (memtest) частота уходит выше 1900 MHz, и там +250 даёт ошибки, даже с потолком 1750 MHz.
  Стабильно везде: **+150**. Мораль: проверять разгон надо и под тяжёлой, и под лёгкой нагрузкой.
- **Память.** Растёт почти линейно до +2250 (6626 MHz, 177 GB/s). На +2500 карта падает с Xid 62
  (зависает внутренний микроконтроллер, лечится перезагрузкой, железу не вредит). Рабочее значение **+2000**.
- Напряжение на мобильных Ampere под Linux не регулируется, поэтому выше по ядру не уйти.

### Прошивка от карты с бо́льшим TGP: не работает

- Платы с RTX 3050 на 60/75 W (TUF F15/A15: TechPowerUp 253414, 247754) имеют Board ID **02A3**, у Vivobook **02A6**.
  Обычный nvflash такую прошивку не ставит. Board ID лежит в образе по смещению `0x9623`.
- Образы Ampere подписаны NVIDIA: менять байты в ROM бесполезно и опасно.
- С nvflash 5.792 и патчем nvflashk прошивка 94.07.3B.80.0B (60/75 W) **встаёт**, карта работает, вычисления без ошибок.
  **Но датчик мощности показывает константу** (6 W или 17 W) при любой нагрузке, а весь ноут в это время берёт
  на 40–50 W больше. Схема измерения тока на другой плате своя, поэтому лимит мощности фактически не работает
  и VRM остаётся без защиты.
- Прошивка 94.07.3B.40.FA (TUF A15, 247754) хуже: драйвер не может запустить карту
  (`RmInitAdapter failed 0x23:0x65`, Xid 62), `nvidia-smi` и службы виснут в ядре. Откат удался только
  с загрузкой без драйвера (`vbios/gpu-recovery-mode`).
- Вывод: чужой vBIOS с другим Board ID на этой плате использовать нельзя, сразу откат на свой.
  Реальный потолок карты в этом ноутбуке: **50 W + разгон**.

## Безопасность

- Без полного бэкапа (`gpu-backup`, около 1 МБ, заголовок `NVGI`) ничего не прошивать.
- Если карта после прошивки не видна в `lspci`, откатить её можно только SPI-программатором (CH341A + SOIC8).
  Экран ноутбука подключён к встроенной AMD-графике, поэтому система загрузится и без рабочей NVIDIA.
- После любой чужой прошивки до долгой нагрузки запустить `vbios/gpu-sensor-check` и сверить с батареей.
- Если драйвер виснет на карте (`RmInitAdapter failed`, `Xid 62`), нужна загрузка без драйвера: `vbios/gpu-recovery-mode`, подробно в [docs/RECOVERY.md](docs/RECOVERY.md).
