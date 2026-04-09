MonopolyStuff

Этот репозиторий содержит скрипт setupMonoVpn.sh для быстрой установки VPN (IKEv2) на Debian-based Linux.

⚠️ Важно:
Скрипт запускается с root-привилегиями (sudo), поэтому внимательно проверяйте его перед запуском.
Скачивайте только с официального репозитория:
```bash
https://github.com/wannarocku/MonopolyStuff
```
Установка:  
Откройте терминал и выполните следующие команды по шагам:
1. Скачиваем архив
```bash
wget https://github.com/wannarocku/MonopolyStuff/archive/refs/heads/main.zip -O MonopolyStuff.zip
```
2. Распаковываем
```bash
unzip MonopolyStuff.zip
cd MonopolyStuff-main
```
3. Просмотр скрипта (рекомендуется):
```bash
less setupMonoVpn.sh
```
4. Делаем скрипт исполняемым:
```bash
chmod +x setupMonoVpn.sh
```
5. Запускаем скрипт с правами root:
```bash
sudo ./setupMonoVpn.sh
```
Одной командой:
```bash
    wget https://github.com/wannarocku/MonopolyStuff/archive/refs/heads/main.zip -O MonopolyStuff.zip
unzip MonopolyStuff.zip
cd MonopolyStuff-main
chmod +x "setupMonoVpn.sh"
sudo ./setupMonoVpn.sh
```
