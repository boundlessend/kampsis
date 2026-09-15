#!/bin/zsh
# отчёт о совместимости MacBook: только читает модель, версию macOS и список HID-устройств Apple
set -euo pipefail

print "Модель: $(/usr/sbin/sysctl -n hw.model)"
print "macOS: $(/usr/bin/sw_vers -productVersion)"
print
print 'Интерфейс угла крышки (Apple, usage page 0x20, usage 0x8A):'
/usr/bin/hidutil list --matching '{"DeviceUsagePage":32,"DeviceUsage":138,"VendorID":1452}'
print
print 'Все сенсоры Apple SPU 0x8104 (сам номер продукта ещё не значит, что угол доступен):'
/usr/bin/hidutil list --matching '{"ProductID":33028,"VendorID":1452}'
